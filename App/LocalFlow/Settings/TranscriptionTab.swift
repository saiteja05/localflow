import SwiftUI
import CaptureKit

struct TranscriptionTab: View {
    @Bindable var appState: AppState
    // Parakeet TDT 0.6b-v3's 25 supported languages (spec §6: auto or pin one of 25).
    private static let parakeetV3Codes = [
        "en", "de", "fr", "es", "it", "pt", "nl", "pl", "sv", "da", "fi", "el", "hu",
        "ro", "sk", "cs", "bg", "hr", "lt", "lv", "et", "sl", "mt", "uk", "ru",
    ]
    private let languages: [(code: String?, name: String)] =
        [(nil, "Auto-detect")] + parakeetV3Codes
            .map { ($0, Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
            .sorted { $0.1 < $1.1 }

    var body: some View {
        Form {
            Picker("Language", selection: Binding(
                get: { appState.settingsStore.settings.languageOverride },
                set: { code in
                    appState.editSettings { $0.languageOverride = code }
                    Task { await appState.parakeet.setLanguage(code) }
                })) {
                ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
            }
            Picker("Microphone", selection: Binding(
                get: { appState.settingsStore.settings.microphoneUID },
                set: { uid in
                    appState.editSettings { $0.microphoneUID = uid }
                    appState.capture.setPreferredInput(uid: uid)
                })) {
                Text("System default").tag(String?.none)
                ForEach(AudioCaptureService.availableInputs(), id: \.uid) {
                    Text($0.name).tag(String?.some($0.uid))
                }
            }
            LabeledContent("Speech model") {
                if appState.modelReady {
                    Label("Parakeet v3 ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .trailing) {
                        ProgressView(value: appState.modelProgress)
                        Text(appState.modelPhaseLabel).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
    }
}
