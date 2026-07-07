import SwiftUI
import AppKit

struct HistoryTab: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Toggle("Keep dictation history (stored only on this Mac)", isOn: Binding(
                get: { appState.settingsStore.settings.historyEnabled },
                set: { on in
                    appState.editSettings { $0.historyEnabled = on }
                    appState.historyStore.isEnabled = on
                }))
            Stepper("Keep last \(appState.settingsStore.settings.historyRetention) dictations",
                    value: Binding(
                        get: { appState.settingsStore.settings.historyRetention },
                        set: { n in
                            appState.editSettings { $0.historyRetention = n }
                            appState.historyStore.retentionLimit = n
                        }), in: 10...1000, step: 10)
            Button("Clear History", role: .destructive) { appState.historyStore.clear() }

            Section("Recent") {
                ForEach(appState.historyStore.entries.suffix(20).reversed(), id: \.timestamp) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.cleanedText).lineLimit(2)
                            Text(e.timestamp, style: .relative).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(e.cleanedText, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
    }
}
