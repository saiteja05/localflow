import Foundation
import Testing
@testable import FlowCore
import CaptureKit
import CleanupKit
import HotkeyKit
import InsertKit
import Persistence
import TranscribeKit

// MARK: mocks

final class MockHotkeySource: HotkeySource, @unchecked Sendable {
    let events: AsyncStream<HotkeyRawEvent>
    let continuation: AsyncStream<HotkeyRawEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream(of: HotkeyRawEvent.self) }
    func start() throws {}
}

final class MockCapture: AudioCapturing, @unchecked Sendable {
    var audioToReturn = AudioData(samples: Array(repeating: 0.1, count: 16_000))  // 1s
    private(set) var startCount = 0, stopCount = 0, cancelCount = 0
    let levels: AsyncStream<Float> = AsyncStream { $0.finish() }
    func startCapture() throws { startCount += 1 }
    func stopCapture() async -> AudioData { stopCount += 1; return audioToReturn }
    func cancelCapture() { cancelCount += 1 }
}

final class MockTranscriber: Transcriber, @unchecked Sendable {
    var result: Result<Transcript, TranscriptionError> = .success(Transcript(text: "raw words", languageHint: nil))
    var delay: TimeInterval = 0
    func isReady() async -> Bool { true }
    func transcribe(_ audio: AudioData) async throws -> Transcript {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return try result.get()
    }
}

struct EchoCleanup: CleanupProcessing {
    func process(_ raw: String, options: CleanupOptions, replacements: [Replacement]) async -> CleanupResult {
        CleanupResult(text: "CLEANED: \(raw)", providerID: "mock")
    }
}

final class MockInserter: TextInserting, @unchecked Sendable {
    var outcome: InsertionOutcome = .inserted(.pasteSwap)
    private(set) var insertedTexts: [String] = []
    func insert(_ text: String, bundleID: String?) async -> InsertionOutcome {
        insertedTexts.append(text)
        return outcome
    }
}

// MARK: harness

@MainActor
struct Harness {
    let hotkeys = MockHotkeySource()
    let capture = MockCapture()
    let transcriber = MockTranscriber()
    let inserter = MockInserter()
    let history: HistoryStore
    let settings: SettingsStore
    let controller: FlowController
    var clock: TimeInterval = 100

    init(cleanup: any CleanupProcessing = EchoCleanup()) {
        let dir = tempDirFC()
        history = HistoryStore(directory: dir)
        let settings = SettingsStore(directory: dir)
        self.settings = settings
        nonisolated(unsafe) var now: TimeInterval = 100
        controller = FlowController(
            hotkeys: hotkeys, capture: capture, transcriber: transcriber,
            cleanup: cleanup, inserter: inserter,
            settings: settings, dictionary: DictionaryStore(directory: dir), history: history,
            frontmostBundleID: { "com.apple.Notes" },
            now: { now })
        self.nowRef = { now = $0 }
    }
    let nowRef: (TimeInterval) -> Void

    /// Simulate a hold of `duration` seconds and wait for the pipeline to finish.
    func dictate(holdFor duration: TimeInterval) async {
        nowRef(100)
        hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        nowRef(100 + duration)
        hotkeys.continuation.yield(.keyUp)
        // Poll until controller returns to a terminal phase.
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(20))
            if case .idle = controller.phase { return }
            if case .notice = controller.phase { return }
        }
    }
}

func tempDirFC() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "flowcore-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: tests

@MainActor
struct FlowControllerTests {
    @Test func happyPathInsertsCleanedTextAndRecordsHistory() async {
        let h = Harness()
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts == ["CLEANED: raw words"])
        #expect(h.history.entries.count == 1)
        #expect(h.history.entries.first?.rawText == "raw words")
        #expect(h.history.entries.first?.appBundleID == "com.apple.Notes")
        #expect(h.controller.lastCleanedText == "CLEANED: raw words")
        #expect(h.capture.startCount == 1 && h.capture.stopCount == 1)
    }
    @Test func callingStartTwiceStillDeliversEvents() async {
        let h = Harness()
        h.controller.start()
        h.controller.start()   // must be a no-op, not kill the event stream
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts == ["CLEANED: raw words"])
    }
    @Test func emptyTranscriptShowsNoticeAndInsertsNothing() async {
        let h = Harness()
        h.transcriber.result = .success(Transcript(text: "", languageHint: nil))
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.history.entries.isEmpty)
        #expect(h.controller.phase == .notice("Didn't catch that"))
    }
    @Test func emptyCleanupResultShowsNoticeAndInsertsNothing() async {
        // Filler-only dictation: transcript non-empty, cleaned text empty.
        struct EmptyCleanup: CleanupProcessing {
            func process(_ raw: String, options: CleanupOptions,
                         replacements: [Replacement]) async -> CleanupResult {
                CleanupResult(text: "", providerID: "rules")
            }
        }
        let h = Harness(cleanup: EmptyCleanup())
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.history.entries.isEmpty)
        #expect(h.controller.phase == .notice("Didn't catch that"))
    }
    @Test func tooShortAudioIsDiscardedViaNotice() async {
        let h = Harness()
        h.capture.audioToReturn = AudioData(samples: Array(repeating: 0, count: 1600)) // 0.1s
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.controller.phase == .notice("Didn't catch that"))
    }
    @Test func transcriberFailureShowsNotice() async {
        let h = Harness()
        h.transcriber.result = .failure(.engineFailure("boom"))
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.controller.phase == .notice("Transcription failed"))
    }
    @Test func insertionFailureNoticesButKeepsHistory() async {
        let h = Harness()
        h.inserter.outcome = .failedTextOnClipboard
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.controller.phase == .notice("Couldn't insert — it's on your clipboard"))
        #expect(h.history.entries.count == 1)
    }
    @Test func escapeCancelsRecordingWithoutInsertion() async {
        let h = Harness()
        h.controller.start()
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        h.hotkeys.continuation.yield(.escapePressed)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.capture.cancelCount == 1)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.controller.phase == .idle)
    }
    @Test func secureInputDisablesAndReenables() async {
        let h = Harness()
        h.controller.start()
        h.hotkeys.continuation.yield(.secureInputChanged(true))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .disabled("Secure input active"))
        // Hotkey presses are ignored while disabled:
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.startCount == 0)
        h.hotkeys.continuation.yield(.secureInputChanged(false))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .idle)
    }
    @Test func recordingPhaseIsVisibleWhileHolding() async {
        let h = Harness()
        h.controller.start()
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.controller.phase == .recording(handsFree: false))
        h.hotkeys.continuation.yield(.keyUp)   // cleanup: end the session
        try? await Task.sleep(for: .milliseconds(200))
    }

    @Test func handsFreeToggleTakesEffectWithoutRestart() async {
        let h = Harness()
        h.controller.start()
        var s = h.settings.settings
        s.handsFreeEnabled = false
        h.settings.update(s)
        // Short tap: with hands-free disabled the tap is discarded immediately,
        // not parked in the 0.4s double-tap window.
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        h.nowRef(100.1)
        h.hotkeys.continuation.yield(.keyUp)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.capture.cancelCount == 1)
        #expect(h.controller.phase == .idle)
    }

    @Test func secureInputDuringProcessingIsNotClobbered() async {
        let h = Harness()
        h.transcriber.delay = 0.3
        h.controller.start()
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        h.nowRef(100.5)
        h.hotkeys.continuation.yield(.keyUp)
        try? await Task.sleep(for: .milliseconds(100))   // pipeline in transcribe sleep
        h.hotkeys.continuation.yield(.secureInputChanged(true))
        try? await Task.sleep(for: .milliseconds(400))   // pipeline has finished by now
        #expect(h.controller.phase == .disabled("Secure input active"))
    }

    @Test func secondDictationWhileProcessingIsIgnored() async {
        let h = Harness()
        h.transcriber.delay = 0.3
        h.controller.start()
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        h.nowRef(100.5)
        h.hotkeys.continuation.yield(.keyUp)
        try? await Task.sleep(for: .milliseconds(100))
        h.hotkeys.continuation.yield(.keyDown)           // during processing
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.startCount == 1)               // ignored
        try? await Task.sleep(for: .milliseconds(400))
        #expect(h.inserter.insertedTexts.count == 1)
    }

    @Test func pauseBlocksDictationAndUnpauseRestores() async {
        let h = Harness()
        h.controller.start()
        h.controller.setPaused(true)
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.startCount == 0)
        #expect(h.controller.phase == .disabled("Paused"))
        h.controller.setPaused(false)
        #expect(h.controller.phase == .idle)
    }

    @Test func pauseDuringSecureInputKeepsSecureReasonAndStaysBlocked() async {
        let h = Harness()
        h.controller.start()
        h.hotkeys.continuation.yield(.secureInputChanged(true))
        try? await Task.sleep(for: .milliseconds(50))
        h.controller.setPaused(true)
        #expect(h.controller.phase == .disabled("Secure input active"))   // warning not masked
        h.controller.setPaused(false)
        #expect(h.controller.phase == .disabled("Secure input active"))   // still blocked
        h.hotkeys.continuation.yield(.secureInputChanged(false))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .idle)                              // both cleared
    }

    @Test func secureInputClearingWhilePausedStaysPaused() async {
        let h = Harness()
        h.controller.start()
        h.controller.setPaused(true)
        h.hotkeys.continuation.yield(.secureInputChanged(true))
        try? await Task.sleep(for: .milliseconds(50))
        h.hotkeys.continuation.yield(.secureInputChanged(false))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .disabled("Paused"))                // pause survives
        #expect(h.controller.isPaused == true)
        h.controller.setPaused(false)
        #expect(h.controller.phase == .idle)
    }

    @Test func hotkeyUnavailabilityDisablesAndClears() async {
        let h = Harness()
        h.controller.start()
        h.controller.setHotkeyAvailability(unavailableReason: "Hotkey inactive — grant Accessibility")
        #expect(h.controller.phase == .disabled("Hotkey inactive — grant Accessibility"))
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.startCount == 0)                                // keys ignored while dead
        h.controller.setHotkeyAvailability(unavailableReason: nil)
        #expect(h.controller.phase == .idle)
    }

    @Test func disabledReasonPriorityIsSecureThenUnavailableThenPaused() async {
        let h = Harness()
        h.controller.start()
        h.controller.setPaused(true)
        h.controller.setHotkeyAvailability(unavailableReason: "Hotkey inactive")
        #expect(h.controller.phase == .disabled("Hotkey inactive"))       // outranks Paused
        h.hotkeys.continuation.yield(.secureInputChanged(true))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .disabled("Secure input active"))   // outranks both
        h.hotkeys.continuation.yield(.secureInputChanged(false))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .disabled("Hotkey inactive"))
        h.controller.setHotkeyAvailability(unavailableReason: nil)
        #expect(h.controller.phase == .disabled("Paused"))
        h.controller.setPaused(false)
        #expect(h.controller.phase == .idle)
    }
}
