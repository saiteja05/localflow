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
        case editing            // edit hotkey held: recording a spoken instruction
        case transcribing
        case cleaning
        case inserting
        case notice(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastCleanedText: String?
    /// Incremental transcript shown in the HUD while recording ("" when off).
    public private(set) var liveTranscript = ""
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
    private let liveTranscriber: (any LiveTranscribing)?
    private var liveTask: Task<Void, Never>?
    private var liveTypingActiveForSession = false
    private let liveTypist: (any LiveTyping)?
    private let transformer: (any TextTransforming)?
    private let selectionReader: (@Sendable () async -> String?)?
    private var editSelection: String?
    private var editStart: TimeInterval = 0
    private var editCapTimer: Task<Void, Never>?

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
                sessionCap: TimeInterval = 600,
                liveTranscriber: (any LiveTranscribing)? = nil,
                liveTypist: (any LiveTyping)? = nil,
                transformer: (any TextTransforming)? = nil,
                selectionReader: (@Sendable () async -> String?)? = nil) {
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
        self.liveTranscriber = liveTranscriber
        self.liveTypist = liveTypist
        self.transformer = transformer
        self.selectionReader = selectionReader
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
            guard !pipelineActive, phase != .editing else { return }   // one session at a time
            if !machine.isRecording,
               machine.handsFreeEnabled != settings.settings.handsFreeEnabled {
                machine = GestureMachine(handsFreeEnabled: settings.settings.handsFreeEnabled)
            }
            run(machine.handle(.keyDown(now())))
        case .keyUp:           run(machine.handle(.keyUp(now())))
        case .escapePressed:
            if phase == .editing { cancelEdit() } else { run(machine.handle(.escape)) }
        case .comboCancelled:  run(machine.handle(.comboCancelled))
        case .editKeyDown:     beginEdit()
        case .editKeyUp:       finishEdit()
        case .editCancelled:   cancelEdit()
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
                    startLivePreview()
                } catch {
                    notice("Microphone unavailable")
                }
            case .discardCapture:
                cancelTimers()
                capture.cancelCapture()   // finishes the live chunk stream too
                endLivePreview()
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

    /// HUD preview and/or live-typing: SpeechAnalyzer streams words while the
    /// user speaks; the inserted text still comes from the batch pass. Never
    /// blocks capture. `clearTyped()` runs at the tail of this same sequential
    /// Task (not from `process()`/`.discardCapture`) so it always happens
    /// strictly after the last `update()` — cancelling this Task does not
    /// stop `liveTranscriber`'s producer, which only finishes once
    /// `capture.stopCapture()`/`cancelCapture()` closes the chunk stream, so
    /// clearing from outside this Task could race a still-draining stream.
    private func startLivePreview() {
        let wantsHUD = settings.settings.livePreviewEnabled
        let wantsLiveType = settings.settings.liveTypingEnabled && liveTypist != nil && phase != .editing
        liveTypeDebugLog("startLivePreview: wantsHUD=\(wantsHUD) wantsLiveType=\(wantsLiveType) livePreviewEnabled=\(settings.settings.livePreviewEnabled) liveTypingEnabled=\(settings.settings.liveTypingEnabled) liveTypistIsNil=\(liveTypist == nil) phase=\(phase)")   // DEBUG-LIVETYPE
        liveTypingActiveForSession = wantsLiveType
        guard wantsHUD || wantsLiveType, let liveTranscriber else { return }
        liveTask?.cancel()
        if wantsHUD { liveTranscript = "" }
        let chunks = capture.makeLiveChunkStream()
        liveTask = Task { [weak self] in
            guard let self else { return }
            guard await liveTranscriber.isReady() else { return }
            liveTypeDebugLog("startLivePreview: liveTranscriber ready, about to begin liveTypist")   // DEBUG-LIVETYPE
            if wantsLiveType { await self.liveTypist?.begin() }
            let updates = await liveTranscriber.startSession(chunks: chunks)
            for await update in updates {
                guard !Task.isCancelled else { break }
                if wantsHUD { self.liveTranscript = update.displayText }
                liveTypeDebugLog("startLivePreview: update received, displayText=\(update.displayText.prefix(50)) wantsLiveType=\(wantsLiveType)")   // DEBUG-LIVETYPE
                if wantsLiveType { await self.liveTypist?.update(update.displayText) }
            }
            if wantsLiveType { await self.liveTypist?.clearTyped() }
        }
    }

    private func endLivePreview() {
        liveTask?.cancel()
        liveTask = nil
        liveTranscript = ""
        let transcriber = liveTranscriber
        Task { await transcriber?.endSession() }
    }

    // MARK: edit mode (hold Right ⌥ with text selected, speak an instruction)

    private func beginEdit() {
        guard phase == .idle, !pipelineActive, !machine.isRecording,
              transformer != nil, let selectionReader else { return }
        editStart = now()
        phase = .editing
        Task { [weak self] in
            guard let self else { return }
            let selection = await selectionReader()
            guard self.phase == .editing else { return }   // released/cancelled meanwhile
            guard let selection, !selection.isEmpty else {
                self.cancelEdit()
                self.notice("Select text first, then hold the edit key")
                return
            }
            self.editSelection = selection
            do {
                try self.capture.startCapture()
                self.startLivePreview()
                self.editCapTimer = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(self.sessionCap))
                    guard !Task.isCancelled else { return }
                    self.finishEdit()
                }
            } catch {
                self.cancelEdit()
                self.notice("Microphone unavailable")
            }
        }
    }

    private func finishEdit() {
        guard phase == .editing else { return }
        editCapTimer?.cancel(); editCapTimer = nil
        let selection = editSelection
        editSelection = nil
        guard let selection, now() - editStart >= 0.3 else {
            cancelEdit()
            return
        }
        pipelineActive = true
        Task { [weak self] in await self?.processEdit(selection: selection) }
    }

    private func cancelEdit() {
        editCapTimer?.cancel(); editCapTimer = nil
        editSelection = nil
        capture.cancelCapture()
        endLivePreview()
        if phase == .editing { phase = .idle }
    }

    private func processEdit(selection: String) async {
        pipelineActive = true
        defer { pipelineActive = false }
        setPhase(.transcribing)
        let audio = await capture.stopCapture()
        endLivePreview()
        guard audio.duration >= 0.35 else { return notice("Didn't catch that") }
        let instruction: String
        do {
            instruction = try await transcriber.transcribe(audio).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return notice("Transcription failed")
        }
        guard !instruction.isEmpty else { return notice("Didn't catch that") }
        setPhase(.cleaning)
        guard let transformer,
              let edited = await transformer.transform(selection, instruction: instruction) else {
            return notice("Edits need an AI provider — none available")
        }
        setPhase(.inserting)
        // Pasting replaces the active selection in every target we support.
        let outcome = await inserter.insert(edited, bundleID: frontmostBundleID())
        lastCleanedText = edited
        switch outcome {
        case .inserted:              setPhase(.idle)
        case .failedTextOnClipboard: notice("Couldn't insert — it's on your clipboard")
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
        let audio = await capture.stopCapture()   // finishes the live chunk stream
        let pendingLiveTeardown = liveTypingActiveForSession ? liveTask : nil
        endLivePreview()
        guard audio.duration >= 0.35 else { return notice("Didn't catch that") }

        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(audio)
        } catch {
            return notice("Transcription failed")
        }
        let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return notice("Didn't catch that") }
        let commandsOn = settings.settings.voiceCommandsEnabled
        let commanded = commandsOn ? VoiceCommandProcessor.apply(raw) : raw
        guard !commanded.isEmpty else { return notice("Didn't catch that") }

        setPhase(.cleaning)
        let tone = bundleID.flatMap { settings.settings.appTones[$0] }
            ?? settings.settings.defaultTone
        let options = CleanupOptions(level: settings.settings.cleanupLevel,
                                     vocabulary: dictionary.vocabulary,
                                     tone: tone)
        let result = await cleanup.process(commanded, options: options,
                                           replacements: dictionary.replacements)
        // Filler-only dictation legitimately cleans to empty — never paste "".
        guard !result.text.isEmpty else { return notice("Didn't catch that") }
        let finalText = commandsOn ? VoiceCommandProcessor.applyFormatting(result.text) : result.text

        // clearTyped() (backspacing the live-typed draft) runs at the tail of the
        // live task; without waiting for it here, its backspaces can land after
        // this insert and delete the final text instead of the draft.
        await pendingLiveTeardown?.value
        setPhase(.inserting)
        let outcome = await inserter.insert(finalText, bundleID: bundleID)
        lastCleanedText = finalText

        history.isEnabled = settings.settings.historyEnabled
        if history.retentionLimit != settings.settings.historyRetention {
            history.retentionLimit = settings.settings.historyRetention
        }
        history.add(HistoryEntry(timestamp: Date(), rawText: raw, cleanedText: finalText,
                                 appBundleID: bundleID, providerID: result.providerID))

        switch outcome {
        case .inserted:
            setPhase(.idle)
        case .failedTextOnClipboard:
            notice("Couldn't insert — it's on your clipboard")
        }
    }

    // DEBUG-LIVETYPE
    private func liveTypeDebugLog(_ message: String) {
        let line = "\(Date()): \(message)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/localflow-livetype-debug.log"
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
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
