import Foundation
import CleanupKit
import HotkeyKit

public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: HotkeyChoice = .fnKey
    public var handsFreeEnabled: Bool = true
    public var cleanupLevel: CleanupLevel = .standard
    public var languageOverride: String? = nil      // nil = auto (Parakeet v3 auto-detects)
    public var microphoneUID: String? = nil         // nil = system default input
    public var ollamaEnabled: Bool = true
    public var ollamaModel: String = "qwen3:4b-instruct"
    public var historyEnabled: Bool = true
    public var historyRetention: Int = 100
    public var launchAtLogin: Bool = false
    public var defaultTone: Tone = .neutral            // LLM writing tone unless overridden
    public var appTones: [String: Tone] = [:]          // bundle ID -> tone override
    public var onboardingCompleted: Bool = false

    public init() {}

    // Tolerant decoding: any missing/new key falls back to its default so
    // settings files survive app upgrades in both directions. Note the
    // .flatMap unwrap: `try?` + `decodeIfPresent` yields a double optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        hotkey           = (try? c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)).flatMap { $0 } ?? d.hotkey
        handsFreeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .handsFreeEnabled)).flatMap { $0 } ?? d.handsFreeEnabled
        cleanupLevel     = (try? c.decodeIfPresent(CleanupLevel.self, forKey: .cleanupLevel)).flatMap { $0 } ?? d.cleanupLevel
        languageOverride = (try? c.decodeIfPresent(String.self, forKey: .languageOverride)).flatMap { $0 }
        microphoneUID    = (try? c.decodeIfPresent(String.self, forKey: .microphoneUID)).flatMap { $0 }
        ollamaEnabled    = (try? c.decodeIfPresent(Bool.self, forKey: .ollamaEnabled)).flatMap { $0 } ?? d.ollamaEnabled
        ollamaModel      = (try? c.decodeIfPresent(String.self, forKey: .ollamaModel)).flatMap { $0 } ?? d.ollamaModel
        historyEnabled   = (try? c.decodeIfPresent(Bool.self, forKey: .historyEnabled)).flatMap { $0 } ?? d.historyEnabled
        historyRetention = (try? c.decodeIfPresent(Int.self, forKey: .historyRetention)).flatMap { $0 } ?? d.historyRetention
        launchAtLogin    = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)).flatMap { $0 } ?? d.launchAtLogin
        defaultTone      = (try? c.decodeIfPresent(Tone.self, forKey: .defaultTone)).flatMap { $0 } ?? d.defaultTone
        appTones         = (try? c.decodeIfPresent([String: Tone].self, forKey: .appTones)).flatMap { $0 } ?? d.appTones
        onboardingCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted)).flatMap { $0 } ?? d.onboardingCompleted
    }
}

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var rawText: String
    public var cleanedText: String
    public var appBundleID: String?
    public var providerID: String
    public init(timestamp: Date, rawText: String, cleanedText: String,
                appBundleID: String?, providerID: String) {
        self.timestamp = timestamp
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.appBundleID = appBundleID
        self.providerID = providerID
    }
}

public enum PersistenceLocation {
    public static func applicationSupport() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appending(path: "LocalFlow")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
