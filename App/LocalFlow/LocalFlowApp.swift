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
            let paused = appState.controller.phase == .disabled("Paused")
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

            Divider()
            if case .disabled(let reason) = appState.controller.phase, reason != "Paused" {
                Text("⚠︎ \(reason)")
            }
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

        Settings { SettingsView(appState: appState) }
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
        case .recording:  return "waveform.badge.mic"
        case .transcribing, .cleaning, .inserting: return "hourglass"
        case .disabled:   return "waveform.slash"
        case .idle, .notice: return "waveform"
        }
    }
}
