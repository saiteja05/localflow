import SwiftUI
import CleanupKit

struct CleanupTab: View {
    @Bindable var appState: AppState
    @State private var appleFMAvailable = false
    @State private var ollamaAvailable = false

    var body: some View {
        Form {
            Picker("Cleanup level", selection: Binding(
                get: { appState.settingsStore.settings.cleanupLevel },
                set: { level in
                    appState.editSettings { $0.cleanupLevel = level }
                    Task {
                        await appState.appleFM.prewarm(options: CleanupOptions(
                            level: level, vocabulary: appState.dictionaryStore.vocabulary))
                    }
                })) {
                Text("Off — raw transcription").tag(CleanupLevel.off)
                Text("Light — instant rules only").tag(CleanupLevel.light)
                Text("Standard — AI cleanup").tag(CleanupLevel.standard)
                Text("Heavy — AI cleanup + grammar").tag(CleanupLevel.heavy)
            }
            .pickerStyle(.inline)

            Section("Providers") {
                LabeledContent("Apple Intelligence") {
                    statusBadge(appleFMAvailable,
                                offHint: "Enable Apple Intelligence in System Settings")
                }
                LabeledContent("Ollama") {
                    statusBadge(ollamaAvailable, offHint: "Not running — optional")
                }
                TextField("Ollama model", text: Binding(
                    get: { appState.settingsStore.settings.ollamaModel },
                    set: { m in
                        appState.editSettings { $0.ollamaModel = m }
                        appState.ollama.updateModel(m)
                    }))
                    .help("Model tag to use when Ollama is the cleanup provider")
            }
        }
        .formStyle(.grouped).padding()
        .task {
            appleFMAvailable = await appState.appleFM.isAvailable()
            ollamaAvailable = await appState.ollama.isAvailable()
        }
    }

    private func statusBadge(_ ok: Bool, offHint: String) -> some View {
        Label(ok ? "Available" : offHint,
              systemImage: ok ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(ok ? .green : .secondary)
    }
}
