import SwiftUI
import UniformTypeIdentifiers
import CleanupKit

struct DictionaryTab: View {
    @Bindable var appState: AppState
    @State private var newTerm = ""
    @State private var newSpoken = ""
    @State private var newWritten = ""

    var body: some View {
        Form {
            Section("Vocabulary — words the AI should spell correctly") {
                HStack {
                    TextField("Add term (e.g. Kubernetes)", text: $newTerm)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm).disabled(newTerm.isEmpty)
                }
                ForEach(appState.dictionaryStore.vocabulary, id: \.self) { term in
                    HStack {
                        Text(term); Spacer()
                        Button(role: .destructive) {
                            appState.dictionaryStore.removeVocabulary(term)
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Replacements — always substitute exactly") {
                HStack {
                    TextField("Spoken (eng standup)", text: $newSpoken)
                    Image(systemName: "arrow.right")
                    TextField("Written (Engineering Standup)", text: $newWritten)
                    Button("Add") {
                        appState.dictionaryStore.addReplacement(
                            Replacement(spoken: newSpoken, written: newWritten))
                        newSpoken = ""; newWritten = ""
                    }.disabled(newSpoken.isEmpty || newWritten.isEmpty)
                }
                ForEach(appState.dictionaryStore.replacements, id: \.spoken) { r in
                    HStack {
                        Text("\(r.spoken) → \(r.written)"); Spacer()
                        Button(role: .destructive) {
                            appState.dictionaryStore.removeReplacement(r)
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            importExportSection
        }
        .formStyle(.grouped).padding()
    }

    private func addTerm() {
        appState.dictionaryStore.addVocabulary(newTerm)
        newTerm = ""
    }
}

// Import/export (spec §6) — same JSON schema as the on-disk dictionary.json.
extension DictionaryTab {
    @ViewBuilder var importExportSection: some View {
        Section {
            HStack {
                Button("Import…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url,
                       let data = try? Data(contentsOf: url) {
                        try? appState.dictionaryStore.importData(data)
                    }
                }
                Button("Export…") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.json]
                    panel.nameFieldStringValue = "localflow-dictionary.json"
                    if panel.runModal() == .OK, let url = panel.url,
                       let data = try? appState.dictionaryStore.exportData() {
                        try? data.write(to: url)
                    }
                }
            }
        }
    }
}
