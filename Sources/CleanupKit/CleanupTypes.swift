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

public struct CleanupOptions: Sendable, Equatable {
    public var level: CleanupLevel
    public var vocabulary: [String]
    public init(level: CleanupLevel, vocabulary: [String]) {
        self.level = level
        self.vocabulary = vocabulary
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
