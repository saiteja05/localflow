import SwiftUI

@main
struct LocalFlowApp: App {
    @State private var appState: AppState

    init() {
        // Single construction site — no property-initializer default, which
        // would build (and discard) a second AppState before this init runs.
        let state = AppState()
        _appState = State(initialValue: state)
        Task { await state.bootstrap() }
    }

    var body: some Scene {
        MenuBarExtra {
            // Always-visible status line: active vs inactive must never be a mystery.
            Text(statusLine)
            Divider()

            let paused = appState.controller.isPaused
            Button(paused ? "Resume Dictation" : "Pause Dictation") {
                appState.controller.setPaused(!paused)
            }
            Button("Copy Last Transcript") {
                if let text = appState.controller.lastCleanedText {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .disabled(appState.controller.lastCleanedText == nil)

            Menu("Recent Dictations") {
                ForEach(appState.historyStore.entries.suffix(5).reversed(), id: \.timestamp) { e in
                    Button(String(e.cleanedText.prefix(48))) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.cleanedText, forType: .string)
                    }
                }
            }
            .disabled(appState.historyStore.entries.isEmpty)
            HistoryMenuButton()

            Divider()
            SettingsLink { Text("Settings…") }.keyboardShortcut(",")
            Divider()
            Button("Quit LocalFlow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.menu)

        Window("Welcome to LocalFlow", id: "onboarding") {
            OnboardingView(appState: appState)
        }
        .windowResizability(.contentSize)

        Window("Dictation History", id: "history") {
            HistoryWindowView(appState: appState)
        }
        .windowResizability(.automatic)

        Settings { SettingsView(appState: appState) }
    }

    private var statusLine: String {
        switch appState.controller.phase {
        case .disabled(let reason):   return "⚠︎ \(reason)"
        case .idle:                   return "● Ready — hold \(hotkeyName) to dictate"
        case .recording(let handsFree): return handsFree ? "● Recording (hands-free)…" : "● Recording…"
        case .editing:                return "● Listening for edit…"
        case .transcribing, .cleaning, .inserting: return "● Processing…"
        case .notice(let message):    return message
        }
    }

    private var hotkeyName: String {
        switch appState.settingsStore.settings.hotkey {
        case .rightOption:  return "Right ⌥"   // reserved for edit mode; not offered as dictation key
        case .fnKey:        return "Fn (Globe)"
        case .rightCommand: return "Right ⌘"
        case .custom:       return "your custom hotkey"
        }
    }
}

/// Deviation from the brief's literal snippet: `@Environment(\.openWindow)` is a
/// property wrapper and can only be declared on a View's stored property, not as
/// a local variable inside the MenuBarExtra `label:` @ViewBuilder closure. This
/// helper view holds the environment value and the show-onboarding subscription
/// instead; MenuBarExtra's label just instantiates it.
private struct MenuBarLabel: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: menuIcon)   // Observation-tracked: re-renders on phase change
            .onReceive(NotificationCenter.default.publisher(for: .localFlowShowOnboarding)) { _ in
                openWindow(id: "onboarding")
            }
    }

    private var menuIcon: String {
        switch appState.controller.phase {
        case .recording, .editing:  return "waveform.badge.mic"
        case .transcribing, .cleaning, .inserting: return "hourglass"
        case .disabled:   return "waveform.slash"
        case .idle, .notice: return "waveform"
        }
    }
}

private struct HistoryMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Dictation History…") { openWindow(id: "history") } }
}
