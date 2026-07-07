import AppKit
import SwiftUI
import CleanupKit

struct CleanupTab: View {
    @Bindable var appState: AppState
    @State private var appleFMReason: String?          // nil = available
    @State private var appleFMChecked = false
    @State private var ollamaStatus: OllamaStatus?
    @State private var pullFraction: Double?
    @State private var pullStatus = ""
    @State private var actionError: String?
    private let recommendedModel = "qwen3:4b-instruct"
    // Re-probe while visible: server starts, downloads finish, toggles flip.
    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Picker("Cleanup level", selection: Binding(
                get: { appState.settingsStore.settings.cleanupLevel },
                set: { level in
                    appState.editSettings { $0.cleanupLevel = level }
                    Task {
                        await appState.appleFM.prewarm(options: CleanupOptions(
                            level: level, vocabulary: appState.dictionaryStore.vocabulary,
                            tone: appState.settingsStore.settings.defaultTone))
                    }
                })) {
                Text("Off — raw transcription").tag(CleanupLevel.off)
                Text("Light — instant rules only").tag(CleanupLevel.light)
                Text("Standard — AI cleanup").tag(CleanupLevel.standard)
                Text("Heavy — AI cleanup + grammar").tag(CleanupLevel.heavy)
            }
            .pickerStyle(.inline)

            toneSection

            Section("Providers") {
                appleIntelligenceRow
                ollamaRow
                if case .ready = ollamaStatus { modelPicker }
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped).padding()
        .task { await refresh() }
        .onReceive(poll) { _ in Task { await refresh() } }
    }

    private func refresh() async {
        appleFMReason = await appState.appleFM.unavailabilityReason()
        appleFMChecked = true
        // Don't clobber the status row while a pull is streaming progress.
        if pullFraction == nil {
            ollamaStatus = await appState.ollama.status()
        }
    }

    // MARK: Tone (default + per-app overrides)

    private var toneSection: some View {
        Section("Tone") {
            tonePicker("Default tone", selection: Binding(
                get: { appState.settingsStore.settings.defaultTone },
                set: { t in appState.editSettings { $0.defaultTone = t } }))

            ForEach(appState.settingsStore.settings.appTones.keys.sorted(), id: \.self) { bundleID in
                HStack {
                    tonePicker(appDisplayName(bundleID), selection: Binding(
                        get: { appState.settingsStore.settings.appTones[bundleID] ?? .neutral },
                        set: { t in appState.editSettings { $0.appTones[bundleID] = t } }))
                    Button(role: .destructive) {
                        appState.editSettings { $0.appTones[bundleID] = nil }
                    } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }

            Menu("Add App Override…") {
                ForEach(overrideCandidates, id: \.bundleID) { app in
                    Button(app.name) {
                        appState.editSettings { $0.appTones[app.bundleID] = .casual }
                    }
                }
            }
            Text("Dictations adapt to the app you're speaking into — e.g. casual in Slack, formal in Mail.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tonePicker(_ label: String, selection: Binding<Tone>) -> some View {
        Picker(label, selection: selection) {
            Text("Casual").tag(Tone.casual)
            Text("Neutral").tag(Tone.neutral)
            Text("Formal").tag(Tone.formal)
        }
    }

    /// Regular (Dock-visible) running apps without an override yet.
    private var overrideCandidates: [(bundleID: String, name: String)] {
        let existing = Set(appState.settingsStore.settings.appTones.keys)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, !existing.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appDisplayName(_ bundleID: String) -> String {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?.localizedName ?? bundleID
    }

    // MARK: Apple Intelligence

    private var appleIntelligenceRow: some View {
        LabeledContent("Apple Intelligence") {
            if !appleFMChecked {
                ProgressView().controlSize(.small)
            } else if let reason = appleFMReason {
                HStack(spacing: 6) {
                    Label(reason, systemImage: "minus.circle").foregroundStyle(.secondary)
                    if reason.contains("Turn on") {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                        }
                    }
                }
            } else {
                Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    // MARK: Ollama

    @ViewBuilder private var ollamaRow: some View {
        LabeledContent("Ollama") {
            switch ollamaStatus {
            case nil:
                ProgressView().controlSize(.small)
            case .ready(let resolved, _):
                let configured = appState.settingsStore.settings.ollamaModel
                Label(resolved == configured || resolved.hasPrefix(configured + ":")
                      ? "Available — using \(resolved)"
                      : "Available — using \(resolved) (\(configured) not installed)",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .serverDown:
                HStack(spacing: 6) {
                    Label("Not running — optional", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                    if ollamaIsInstalled {
                        Button("Start Ollama") { startOllama() }
                    } else {
                        Link("Get Ollama…", destination: URL(string: "https://ollama.com/download")!)
                    }
                }
            case .noUsableModel:
                HStack(spacing: 6) {
                    Label("No chat model installed", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                    pullControl
                }
            }
        }
        // Offer the recommended download whenever the server is up but the
        // recommended model isn't installed yet (also hosts pull progress).
        if pullFraction != nil || recommendedIsMissing {
            LabeledContent("Recommended model") { pullControl }
        }
    }

    private var recommendedIsMissing: Bool {
        if case .ready(_, let installed) = ollamaStatus {
            return !installed.contains { $0 == recommendedModel || $0.hasPrefix(recommendedModel + ":") }
        }
        return false
    }

    @ViewBuilder private var pullControl: some View {
        if let fraction = pullFraction {
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 120)
                Text(fraction >= 1 ? "Done" : "\(Int(fraction * 100))% \(pullStatus)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button("Download \(recommendedModel)") { pullRecommended() }
        }
    }

    private func pullRecommended() {
        actionError = nil
        pullFraction = 0
        Task {
            do {
                try await appState.ollama.pullModel(recommendedModel) { fraction, status in
                    Task { @MainActor in
                        pullFraction = fraction
                        pullStatus = status
                    }
                }
                appState.editSettings { $0.ollamaModel = recommendedModel }
                appState.ollama.updateModel(recommendedModel)
            } catch {
                actionError = "Download failed: \(error)"
            }
            pullFraction = nil
            await refresh()
        }
    }

    private var ollamaIsInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/ollama")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama")
    }

    /// Prefer the menu-bar app (keeps serving after we exit); fall back to
    /// the CLI's `ollama serve` as a detached child.
    private func startOllama() {
        actionError = nil
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            NSWorkspace.shared.openApplication(
                at: URL(filePath: "/Applications/Ollama.app"),
                configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let cli = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let cli else { return }
        let process = Process()
        process.executableURL = URL(filePath: cli)
        process.arguments = ["serve"]
        do { try process.run() } catch {
            actionError = "Couldn't start Ollama: \(error.localizedDescription)"
        }
    }

    // MARK: model picker (server up: choose from what's actually installed)

    @ViewBuilder private var modelPicker: some View {
        let configured = appState.settingsStore.settings.ollamaModel
        let installed = installedChatModels
        Picker("Ollama model", selection: Binding(
            get: { configured },
            set: { m in
                appState.editSettings { $0.ollamaModel = m }
                appState.ollama.updateModel(m)
                Task { await refresh() }
            })) {
            ForEach(installed, id: \.self) { Text($0).tag($0) }
            if !installed.contains(configured) {
                Text("\(configured) (not installed)").tag(configured)
            }
        }
        .help("Which installed Ollama model cleans your dictation")
    }

    private var installedChatModels: [String] {
        // Derive from the status probe rather than re-fetching /api/tags.
        if case .ready(_, let installed) = ollamaStatus {
            return installed.filter { !$0.lowercased().contains("embed") }
        }
        return []
    }
}
