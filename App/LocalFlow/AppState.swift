import AppKit
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
    let systemTranscriber: SystemTranscriber
    let appleFM: AppleFMCleaner
    let ollama: OllamaCleaner
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
        ollama = OllamaCleaner(model: settingsStore.settings.ollamaModel)
        hotkeySource = EventTapHotkeySource(choice: settingsStore.settings.hotkey)

        // Fallback locale mirrors the user's language override so the
        // SpeechAnalyzer fallback isn't stuck on en_US for non-English users.
        let fallbackLocale = settingsStore.settings.languageOverride
            .map { Locale(identifier: $0) } ?? Locale.current
        systemTranscriber = SystemTranscriber(locale: fallbackLocale)
        let transcriber = TranscriberRouter(primary: parakeet, fallback: systemTranscriber)
        let pipeline = CleanupPipeline(providers: [appleFM, ollama])
        controller = FlowController(
            hotkeys: hotkeySource, capture: capture, transcriber: transcriber,
            cleanup: pipeline, inserter: TextInserter(),
            settings: settingsStore, dictionary: dictionaryStore, history: historyStore,
            liveTranscriber: SystemLiveTranscriber(locale: fallbackLocale),
            liveTypist: LiveTypist(),
            transformer: pipeline,
            selectionReader: { await SelectionReader.currentSelection() })
    }

    /// Idempotent: safe to re-run whenever permissions change (onboarding's
    /// Continue buttons call this again). Nothing user-facing waits on the
    /// model download — heavy engine prep runs once, in the background.
    func bootstrap() async {
        refreshPermissions()
        controller.start()                       // idempotent

        if hud == nil {
            hud = HUDPanelController(controller: controller, levels: capture.levels)
            hud?.observe()
        }

        // Onboarding exists to get the two permissions granted. If both are
        // already in place, consider it done — never nag on every launch just
        // because the user closed the window without clicking Done.
        if !settingsStore.settings.onboardingCompleted,
           accessibilityGranted, microphoneGranted {
            var s = settingsStore.settings
            s.onboardingCompleted = true
            settingsStore.update(s)
        }

        if !settingsStore.settings.onboardingCompleted
            || !accessibilityGranted || !microphoneGranted {
            NSApplication.shared.activate()
            // openWindow is a View concern: post a notification the app scene observes.
            NotificationCenter.default.post(name: .localFlowShowOnboarding, object: nil)
        }

        startEnginePreparation()
        startHotkeyWatchdog()
    }

    /// Re-runnable permission refresh (onboarding Continue calls bootstrap again).
    private func refreshPermissions() {
        accessibilityGranted = Permissions.accessibilityGranted
        microphoneGranted = AudioCaptureService.microphoneAuthorized
        if microphoneGranted { try? capture.warmUp() }
        if accessibilityGranted { try? hotkeySource.start() }   // idempotent
        // Surface silent tap death (missing/stale Accessibility grant) instead
        // of looking idle — and clear it the moment the tap is alive.
        controller.setHotkeyAvailability(unavailableReason: hotkeySource.isRunning
            ? nil
            : "Hotkey inactive — grant Accessibility in System Settings")
    }

    private var hotkeyWatchdogStarted = false

    /// Retries the event tap until it's alive (e.g. the user grants
    /// Accessibility from System Settings without touching onboarding).
    private func startHotkeyWatchdog() {
        guard !hotkeyWatchdogStarted else { return }
        hotkeyWatchdogStarted = true
        Task { [weak self] in
            while true {
                guard let self else { return }
                if self.hotkeySource.isRunning { return }
                try? await Task.sleep(for: .seconds(3))
                self.refreshPermissions()
            }
        }
    }

    private var enginePreparationStarted = false

    /// One-shot background prep: Apple FM prewarm, SpeechAnalyzer fallback
    /// asset (covers dictation while Parakeet downloads), then Parakeet.
    private func startEnginePreparation() {
        guard !enginePreparationStarted else { return }
        enginePreparationStarted = true
        Task { [weak self] in
            guard let self else { return }
            // Prewarm Apple FM so the first dictation's cleanup is warm (spec §2).
            await self.appleFM.prewarm(options: CleanupOptions(
                level: self.settingsStore.settings.cleanupLevel,
                vocabulary: self.dictionaryStore.vocabulary,
                tone: self.settingsStore.settings.defaultTone))
            // Fallback ready early; unsupported locale throws — acceptable,
            // Parakeet covers shortly after.
            try? await self.systemTranscriber.prepare()
            try? await self.parakeet.prepare { [weak self] fraction, label in
                Task { @MainActor in
                    self?.modelProgress = fraction
                    self?.modelPhaseLabel = label
                }
            }
            let ready = await self.parakeet.isReady()
            self.modelReady = ready
            await self.parakeet.setLanguage(self.settingsStore.settings.languageOverride)
        }
    }
}

extension Notification.Name {
    static let localFlowShowOnboarding = Notification.Name("localFlowShowOnboarding")
}
