import SwiftUI
import CaptureKit
import HotkeyKit

struct OnboardingView: View {
    @Bindable var appState: AppState
    @State private var step = 0
    // Poll grants: AX/mic status have no change notifications.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case 0: welcome
            case 1: microphone
            case 2: accessibility
            case 3: model
            default: tryIt
            }
        }
        .padding(32)
        .frame(width: 460, height: 340)
        .onReceive(poll) { _ in
            appState.microphoneGranted = AudioCaptureService.microphoneAuthorized
            appState.accessibilityGranted = Permissions.accessibilityGranted
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 44))
            Text("Welcome to LocalFlow").font(.title.bold())
            Text("Hold **Fn**, speak, release — polished text appears wherever your cursor is. Everything runs on this Mac; your voice never leaves it.")
                .multilineTextAlignment(.center)
            Button("Get Started") { step = 1 }.buttonStyle(.borderedProminent)
        }
    }

    private var microphone: some View {
        permissionStep(
            title: "Microphone",
            detail: "LocalFlow needs the microphone to hear you. Audio is processed on-device and discarded after each dictation.",
            granted: appState.microphoneGranted,
            request: { Task { _ = await AudioCaptureService.requestMicrophoneAccess() } },
            next: { step = 2 })
    }

    private var accessibility: some View {
        permissionStep(
            title: "Accessibility",
            detail: "This lets LocalFlow type the transcribed text into other apps and listen for the Fn key. Enable LocalFlow in System Settings → Privacy & Security → Accessibility.",
            granted: appState.accessibilityGranted,
            request: {
                Permissions.requestAccessibility()
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            },
            next: { step = 3 })
    }

    private var model: some View {
        VStack(spacing: 12) {
            Text("Downloading speech model").font(.title2.bold())
            Text("Parakeet v3 (~600 MB, one time). You can already dictate using Apple's built-in model while this finishes.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            ProgressView(value: appState.modelReady ? 1 : appState.modelProgress)
            Text(appState.modelReady ? "Ready" : appState.modelPhaseLabel)
                .font(.caption).foregroundStyle(.secondary)
            Button(appState.modelReady ? "Continue" : "Continue (download in background)") { step = 4 }
                .buttonStyle(.borderedProminent)
        }
    }

    private var tryIt: some View {
        VStack(spacing: 12) {
            Text("Try it").font(.title2.bold())
            Text("Click into the field below, then **hold Fn** and say hello.")
            TextField("Dictate here…", text: .constant("")).textFieldStyle(.roundedBorder)
            if let last = appState.controller.lastCleanedText {
                Text("Heard: “\(last)”").foregroundStyle(.secondary)
            }
            Button("Done") {
                var s = appState.settingsStore.settings
                s.onboardingCompleted = true
                appState.settingsStore.update(s)
                NSApplication.shared.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!(appState.microphoneGranted && appState.accessibilityGranted))
        }
    }

    private func permissionStep(title: String, detail: String, granted: Bool,
                                request: @escaping () -> Void,
                                next: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(title).font(.title2.bold())
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
            }
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if granted {
                Button("Continue") { Task { await appState.bootstrap() }; next() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Grant \(title) Access") { request() }.buttonStyle(.borderedProminent)
            }
        }
    }
}
