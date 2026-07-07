import SwiftUI
import HotkeyKit
import Persistence
import ServiceManagement

struct GeneralTab: View {
    @Bindable var appState: AppState
    @State private var recordingHotkey = false
    @State private var hotkeyMonitor: Any?

    // NSEvent device-independent modifier bits (⌘ 1<<20, ⌥ 1<<19, ⌃ 1<<18, ⇧ 1<<17)
    // coincide with the CGEventFlags masks in HotkeyKit.KeyFlags, so the recorded
    // rawValue is directly usable by KeyEventInterpreter.
    private var customHotkeyLabel: String {
        if case .custom(let keyCode, _) = appState.settingsStore.settings.hotkey {
            return "Custom (key \(keyCode))"
        }
        return "Custom"
    }

    var body: some View {
        Form {
            Picker("Dictation hotkey", selection: Binding(
                get: { appState.settingsStore.settings.hotkey },
                set: { choice in
                    appState.editSettings { $0.hotkey = choice }
                    appState.hotkeySource.updateChoice(choice)
                })) {
                Text("Hold Fn (Globe)").tag(HotkeyChoice.fnKey)
                Text("Hold Right ⌘").tag(HotkeyChoice.rightCommand)
                // Show a currently-set custom combo so the Picker has a matching tag.
                if case .custom = appState.settingsStore.settings.hotkey {
                    Text(customHotkeyLabel).tag(appState.settingsStore.settings.hotkey)
                }
            }
            LabeledContent("Custom hotkey") {
                Button(recordingHotkey ? "Press your key combo…" : "Record Custom Hotkey…") {
                    recordingHotkey = true
                    // Local monitor: only sees events while Settings is the key window.
                    hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        // Escape cancels recording without committing any change.
                        if event.keyCode == 53 {
                            if let m = hotkeyMonitor { NSEvent.removeMonitor(m); hotkeyMonitor = nil }
                            recordingHotkey = false
                            return nil
                        }
                        // Require at least one modifier so a bare letter/digit/Escape can
                        // never become a global, system-wide-swallowed hotkey.
                        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                        guard !mods.isEmpty else { return nil }
                        let choice = HotkeyChoice.custom(
                            keyCode: UInt16(event.keyCode),
                            modifierRawValue: UInt64(mods.rawValue))
                        appState.editSettings { $0.hotkey = choice }
                        appState.hotkeySource.updateChoice(choice)
                        recordingHotkey = false
                        if let m = hotkeyMonitor { NSEvent.removeMonitor(m); hotkeyMonitor = nil }
                        return nil   // swallow the keystroke
                    }
                }
                .disabled(recordingHotkey)
            }
            if recordingHotkey {
                Text("Press a key with ⌘/⌥/⌃/⇧ — Esc cancels")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Double-tap for hands-free mode", isOn: Binding(
                get: { appState.settingsStore.settings.handsFreeEnabled },
                set: { on in appState.editSettings { $0.handsFreeEnabled = on } }))
            Toggle("Launch at login", isOn: Binding(
                get: { appState.settingsStore.settings.launchAtLogin },
                set: { on in
                    appState.editSettings { $0.launchAtLogin = on }
                    if on { try? SMAppService.mainApp.register() }
                    else { try? SMAppService.mainApp.unregister() }
                }))
            Text("Tip: set System Settings → Keyboard → “Press 🌐 key” to “Do Nothing” so the emoji picker never appears.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).padding()
    }
}
