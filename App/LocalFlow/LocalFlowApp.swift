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
            Button("Quit LocalFlow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: menuIcon)   // Observation-tracked: re-renders on phase change
        }
        .menuBarExtraStyle(.menu)
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
