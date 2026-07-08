import SwiftUI
import AppKit
import Persistence

/// Full, searchable dictation history (vs. the Settings History tab's
/// capped-at-20 inline list). Reads `historyStore.entries` directly so the
/// list updates live as new dictations land, same mechanism `HistoryTab` relies on.
struct HistoryWindowView: View {
    @Bindable var appState: AppState
    @State private var query = ""

    private var filtered: [HistoryEntry] {
        let all = appState.historyStore.entries.reversed()
        guard !query.isEmpty else { return Array(all) }
        return all.filter { $0.cleanedText.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(filtered, id: \.timestamp) { entry in
                    row(for: entry)
                }
            }
            .listStyle(.plain)
        }
        .searchable(text: $query, prompt: "Search dictations")
        .navigationTitle("Dictation History")
        .frame(minWidth: 420, idealWidth: 560, minHeight: 320, idealHeight: 640)
    }

    private func row(for entry: HistoryEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.cleanedText)
                HStack(spacing: 6) {
                    Text(entry.timestamp, style: .relative).font(.caption).foregroundStyle(.secondary)
                    if let bundleID = entry.appBundleID {
                        Text("· \(AppDisplayName.resolve(bundleID))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.cleanedText, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
