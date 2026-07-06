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

    public func start() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.hotkeys.events {
                self.handleHotkey(event)
            }
        }
    }

    private func handleHotkey(_ event: HotkeyRawEvent) {
        if case .secureInputChanged(let active) = event {
            if active {
                if machine.isRecording { run(machine.handle(.escape)) }
                // Name the app holding secure input when we can (spec §5).
                let holder = Permissions.secureInputAppName().map { " (\($0))" } ?? ""
                phase = .disabled("Secure input active" + holder)
            } else if case .disabled = phase {
                phase = .idle
            }
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
        let options = CleanupOptions(level: settings.settings.cleanupLevel,
                                     vocabulary: dictionary.vocabulary)
        let result = await cleanup.process(raw, options: options,
                                           replacements: dictionary.replacements)
        // Filler-only dictation legitimately cleans to empty — never paste "".
        guard !result.text.isEmpty else { return notice("Didn't catch that") }

        setPhase(.inserting)
        let bundleID = frontmostBundleID()
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
