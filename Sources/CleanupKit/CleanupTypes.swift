import Foundation

public enum CleanupLevel: String, Codable, CaseIterable, Sendable {
    case off, light, standard, heavy
}

public struct Replacement: Codable, Equatable, Sendable {
    public var spoken: String
    public var written: String
    public init(spoken: String, written: String) {
        self.spoken = spoken
        self.written = written
    }
}

/// Writing tone applied by the LLM pass, resolvable per frontmost app
/// (casual in Slack, formal in Mail). `.neutral` adds no directive.
public enum Tone: String, Codable, CaseIterable, Sendable {
    case casual, neutral, formal
}

public struct CleanupOptions: Sendable, Equatable {
    public var level: CleanupLevel
    public var vocabulary: [String]
    public var tone: Tone
    public init(level: CleanupLevel, vocabulary: [String], tone: Tone = .neutral) {
        self.level = level
        self.vocabulary = vocabulary
        self.tone = tone
    }
}

public struct CleanupResult: Sendable, Equatable {
    public var text: String
    public var providerID: String
    public init(text: String, providerID: String) {
        self.text = text
        self.providerID = providerID
    }
}

public protocol CleanupProvider: Sendable {
    var id: String { get }
    func isAvailable() async -> Bool
    func clean(_ text: String, options: CleanupOptions) async throws -> String
    /// Edit mode: apply a spoken instruction to selected text.
    func transform(_ text: String, instruction: String) async throws -> String
}

public extension CleanupProvider {
    /// Providers without edit support (e.g. rules) opt out by default.
    func transform(_ text: String, instruction: String) async throws -> String {
        throw CleanupError.unavailable
    }
}

/// Edit-mode entry point consumed by FlowCore (implemented by CleanupPipeline).
public protocol TextTransforming: Sendable {
    /// nil when no AI provider is available — edits REQUIRE an LLM.
    func transform(_ text: String, instruction: String) async -> String?
}

public protocol CleanupProcessing: Sendable {
    func process(_ raw: String, options: CleanupOptions, replacements: [Replacement]) async -> CleanupResult
}

public enum CleanupError: Error, Equatable {
    case unavailable
    case timedOut
    case refused          // guardrail / safety refusal
    case badResponse(String)
}
