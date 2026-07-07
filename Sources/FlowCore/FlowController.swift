import Foundation
import Observation
import CaptureKit
import CleanupKit
import HotkeyKit
import InsertKit
import Persistence
import TranscribeKit

/// Orchestrates: hotkey events -> GestureMachine -> capture/transcribe/clean/insert.
/// UI observes `phase`; all pipeline work runs off the main actor via Tasks.
@MainActor
@Observable
public final class FlowController {
    public enum Phase: Equatable, Sendable {
        case disabled(String)
        case idle
        case recording(handsFree: Bool)
        case transcribing
        case cleaning
        case inserting
        case notice(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastCleanedText: String?
    public private(set) var isPaused = false
    private var secureInputActive = false
    private var hotkeyUnavailableReason: String?

    private let hotkeys: any HotkeySource
    private let capture: any AudioCapturing
    private let transcriber: any Transcriber
    private let cleanup: any CleanupProcessing
    private let inserter: any TextInserting
    private let settings: SettingsStore
    private let dictionary: DictionaryStore
    private let history: HistoryStore
    private let frontmostBundleID: @Sendable () -> String?
    private let now: @Sendable () -> TimeInterval

    private var machine: GestureMachine
    private var eventTask: Task<Void, Never>?
    private var doubleTapTimer: Task<Void, Never>?
    private var capTimer: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    private let sessionCap: TimeInterval
    private var pipelineActive = false

    public init(hotkeys: any HotkeySource,
                capture: any AudioCapturing,
                transcriber: any Transcriber,
                cleanup: any CleanupProcessing,
                inserter: any TextInserting,
                settings: SettingsStore,
                dictionary: DictionaryStore,
                history: HistoryStore,
                frontmostBundleID: @escaping @Sendable () -> String? = { FrontmostApp.bundleID() },
                now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
                sessionCap: TimeInterval = 600) {
        self.hotkeys = hotkeys
        self.capture = capture
        self.transcriber = transcriber
        self.cleanup = cleanup
        self.inserter = inserter
        self.settings = settings
        self.dictionary = dictionary
        self.history = history
        self.frontmostBundleID = frontmostBundleID
        self.now = now
        self.sessionCap = sessionCap
        self.machine = GestureMachine(handsFreeEnabled: settings.settings.handsFreeEnabled)
    }

    /// Reason priority: secure input > hotkey unavailable > paused. The
    /// disabled state clears only when ALL conditions are gone.
    private func refreshDisabledState() {
        if secureInputActive {
            let holder = Permissions.secureInputAppName().map { " (\($0))" } ?? ""
            phase = .disabled("Secure input active" + holder)
        } else if let reason = hotkeyUnavailableReason {
            phase = .disabled(reason)
        } else if isPaused {
            phase = .disabled("Paused")
        } else if case .disabled = phase {
            phase = .idle
        }
    }

    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused, machine.isRecording { run(machine.handle(.escape)) }
        refreshDisabledState()
    }

    /// The app layer reports whether the event tap is actually delivering
    /// (nil = healthy). Surfaces the silent-tap-death failure mode: without
    /// this, a missing Accessibility grant looks identical to idle.
    public func setHotkeyAvailability(unavailableReason: String?) {
        guard unavailableReason != hotkeyUnavailableReason else { return }
        hotkeyUnavailableReason = unavailableReason
        refreshDisabledState()
    }

    public func start() {
        // Idempotent: cancelling the Task that iterates the AsyncStream would
        // terminate the stream permanently, killing hotkey delivery for good.
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.hotkeys.events {
                self.handleHotkey(event)
            }
        }
    }

    private func handleHotkey(_ event: HotkeyRawEvent) {
        if case .secureInputChanged(let active) = event {
            secureInputActive = active
            if active, machine.isRecording { run(machine.handle(.escape)) }
            refreshDisabledState()
            return
        }
        if case .disabled = phase { return }   // ignore keys while disabled

        switch event {
        case .keyDown:
            guard !pipelineActive else { return }   // one dictation at a time
            if !machine.isRecording,
               machine.handsFreeEnabled != settings.settings.handsFreeEnabled {
                machine = GestureMachine(handsFreeEnabled: settings.settings.handsFreeEnabled)
            }
            run(machine.handle(.keyDown(now())))
        case .keyUp:           run(machine.handle(.keyUp(now())))
        case .escapePressed:   run(machine.handle(.escape))
        case .comboCancelled:  run(machine.handle(.comboCancelled))
        case .secureInputChanged: break
        }
    }

    private func run(_ effects: [GestureMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startCapture:
                do {
                    try capture.startCapture()
                    phase = .recording(handsFree: machine.isHandsFree)
                    startCapTimer()
                } catch {
                    notice("Microphone unavailable")
                }
            case .discardCapture:
                cancelTimers()
                capture.cancelCapture()
                phase = .idle
            case .stopAndProcess:
                cancelTimers()
                // Set synchronously so a keyDown arriving before the Task runs
                // can't start a second dictation (process() re-sets + defers false).
                pipelineActive = true
                Task { [weak self] in await self?.process() }
            case .scheduleDoubleTapTimer:
                doubleTapTimer?.cancel()
                let window = machine.doubleTapWindow
                doubleTapTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(window))
                    guard let self, !Task.isCancelled else { return }
                    self.run(self.machine.handle(.doubleTapTimerFired(self.now())))
                }
            }
        }
        // Recording phase can change (e.g. tapPending -> handsFree) without effects.
        if machine.isRecording, case .recording = phase {
            phase = .recording(handsFree: machine.isHandsFree)
        }
    }

    private func startCapTimer() {
        capTimer?.cancel()
        capTimer = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.sessionCap))
            guard !Task.isCancelled else { return }
            self.run(self.machine.handle(.capTimerFired))
        }
    }

    private func cancelTimers() {
        doubleTapTimer?.cancel(); doubleTapTimer = nil
        capTimer?.cancel(); capTimer = nil
    }

    /// Pipeline phase writes must not clobber .disabled — secure input can
    /// engage while a dictation is still processing.
    private func setPhase(_ p: Phase) {
        if case .disabled = phase { return }
        phase = p
    }

    private func process() async {
        pipelineActive = true
        defer { pipelineActive = false }

        // Captured once: the app the user dictated into. Drives per-app tone
        // AND the insertion strategy, so both see the same app.
        let bundleID = frontmostBundleID()

        setPhase(.transcribing)
        let audio = await capture.stopCapture()
        guard audio.duration >= 0.35 else { return notice("Didn't catch that") }

        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(audio)
        } catch {
            return notice("Transcription failed")
        }
        let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return notice("Didn't catch that") }

        setPhase(.cleaning)
        let tone = bundleID.flatMap { settings.settings.appTones[$0] }
            ?? settings.settings.defaultTone
        let options = CleanupOptions(level: settings.settings.cleanupLevel,
                                     vocabulary: dictionary.vocabulary,
                                     tone: tone)
        let result = await cleanup.process(raw, options: options,
                                           replacements: dictionary.replacements)
        // Filler-only dictation legitimately cleans to empty — never paste "".
        guard !result.text.isEmpty else { return notice("Didn't catch that") }

        setPhase(.inserting)
        let outcome = await inserter.insert(result.text, bundleID: bundleID)
        lastCleanedText = result.text

        history.isEnabled = settings.settings.historyEnabled
        if history.retentionLimit != settings.settings.historyRetention {
            history.retentionLimit = settings.settings.historyRetention
        }
        history.add(HistoryEntry(timestamp: Date(), rawText: raw, cleanedText: result.text,
                                 appBundleID: bundleID, providerID: result.providerID))

        switch outcome {
        case .inserted:
            setPhase(.idle)
        case .failedTextOnClipboard:
            notice("Couldn't insert — it's on your clipboard")
        }
    }

    private func notice(_ message: String) {
        setPhase(.notice(message))
        scheduleNoticeClear()
    }

    private func scheduleNoticeClear() {
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if case .notice = self.phase { self.phase = .idle }
        }
    }
}
