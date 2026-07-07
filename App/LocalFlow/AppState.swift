import Foundation
import Observation
import CaptureKit
import CleanupKit
import FlowCore
import HotkeyKit
import InsertKit
import Persistence
import TranscribeKit

/// Composition root: builds the real object graph and boots the pipeline.
@MainActor
@Observable
final class AppState {
    let settingsStore: SettingsStore
    let dictionaryStore: DictionaryStore
    let historyStore: HistoryStore
    let capture: AudioCaptureService
    let parakeet: ParakeetTranscriber
    let appleFM: AppleFMCleaner
    let hotkeySource: EventTapHotkeySource
    let controller: FlowController
    private var hud: HUDPanelController?

    var modelProgress: Double = 0
    var modelPhaseLabel: String = ""
    var modelReady = false
    var accessibilityGranted = Permissions.accessibilityGranted
    var microphoneGranted = AudioCaptureService.microphoneAuthorized

    init() {
        let dir = PersistenceLocation.applicationSupport()
        settingsStore = SettingsStore(directory: dir)
        dictionaryStore = DictionaryStore(directory: dir)
        historyStore = HistoryStore(directory: dir)
        capture = AudioCaptureService()
        parakeet = ParakeetTranscriber()
        appleFM = AppleFMCleaner()
        hotkeySource = EventTapHotkeySource(choice: settingsStore.settings.hotkey)

        let transcriber = TranscriberRouter(primary: parakeet, fallback: SystemTranscriber())
        let pipeline = CleanupPipeline(providers: [
            appleFM,
            OllamaCleaner(model: settingsStore.settings.ollamaModel),
        ])
        controller = FlowController(
            hotkeys: hotkeySource, capture: capture, transcriber: transcriber,
            cleanup: pipeline, inserter: TextInserter(),
            settings: settingsStore, dictionary: dictionaryStore, history: historyStore)
    }

    /// Idempotent: safe to re-run whenever permissions change.
    func bootstrap() async {
        accessibilityGranted = Permissions.accessibilityGranted
        microphoneGranted = AudioCaptureService.microphoneAuthorized

        if microphoneGranted { try? capture.warmUp() }
        if accessibilityGranted { try? hotkeySource.start() }
        controller.start()

        // Prewarm Apple FM so the first dictation's cleanup is warm (spec §2).
        await appleFM.prewarm(options: CleanupOptions(
            level: settingsStore.settings.cleanupLevel,
            vocabulary: dictionaryStore.vocabulary))

        // Parakeet: download in background; SpeechAnalyzer covers the meantime.
        if !modelReady {
            try? await parakeet.prepare { [weak self] fraction, label in
                Task { @MainActor in
                    self?.modelProgress = fraction
                    self?.modelPhaseLabel = label
                }
            }
            modelReady = await parakeet.isReady()
        }
        await parakeet.setLanguage(settingsStore.settings.languageOverride)

        if hud == nil {
            hud = HUDPanelController(controller: controller, levels: capture.levels)
            hud?.observe()
        }
    }
}
