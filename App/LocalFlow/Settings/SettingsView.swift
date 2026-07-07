import SwiftUI
import Persistence

struct SettingsView: View {
    @Bindable var appState: AppState
    var body: some View {
        TabView {
            GeneralTab(appState: appState).tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionTab(appState: appState).tabItem { Label("Transcription", systemImage: "waveform") }
            CleanupTab(appState: appState).tabItem { Label("AI Cleanup", systemImage: "wand.and.stars") }
            DictionaryTab(appState: appState).tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab(appState: appState).tabItem { Label("History", systemImage: "clock") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 400)
    }
}

// Shared helper: every tab edits a local copy of AppSettings and writes it back
// through this single choke point, so SettingsStore.update(_:) is the only writer.
extension AppState {
    func editSettings(_ change: (inout AppSettings) -> Void) {
        var s = settingsStore.settings
        change(&s)
        settingsStore.update(s)
    }
}
