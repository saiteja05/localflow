import Foundation
import FoundationModels

/// Seam so unit tests never touch the real on-device model.
protocol FMBackend: Sendable {
    func isAvailable() async -> Bool
    /// nil when available; otherwise a user-facing explanation of why not.
    func unavailabilityReason() async -> String?
    /// Throws CleanupError only (maps FoundationModels errors internally).
    func respond(instructions: String, prompt: String, temperature: Double) async throws -> String
    func prewarm(instructions: String) async
}

public actor AppleFMCleaner: CleanupProvider {
    public nonisolated let id = "apple-fm"
    private let backend: any FMBackend

    public init() { self.backend = SystemFMBackend() }
    init(backend: any FMBackend) { self.backend = backend }

    public func isAvailable() async -> Bool { await backend.isAvailable() }

    /// nil when available; otherwise the precise reason (device unsupported /
    /// toggle off / model still downloading) so the UI never shows a generic hint.
    public func unavailabilityReason() async -> String? {
        await backend.unavailabilityReason()
    }

    public func clean(_ text: String, options: CleanupOptions) async throws -> String {
        let out = try await backend.respond(
            instructions: PromptBuilder.instructions(level: options.level,
                                                     vocabulary: options.vocabulary,
                                                     tone: options.tone),
            prompt: PromptBuilder.userPrompt(for: text),
            temperature: 0.2)
        var cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Small models occasionally wrap output in quotes despite instructions.
        if cleaned.count > 1, cleaned.hasPrefix("\""), cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleaned.isEmpty else { throw CleanupError.badResponse("empty model output") }
        return cleaned
    }

    /// Call after launch and whenever cleanup settings change (FlowController does this).
    /// Prewarm with the caller's default tone — the session cache is keyed by
    /// the full instructions string, so a mismatched tone would miss it.
    public func prewarm(options: CleanupOptions) async {
        await backend.prewarm(instructions: PromptBuilder.instructions(
            level: options.level, vocabulary: options.vocabulary, tone: options.tone))
    }
}

/// Real backend. "Next session" pattern: keep ONE fresh, prewarmed, unused session ready;
/// consume it per request (Apple guidance: new session per independent request — the 4096-token
/// window includes the whole transcript, which only grows).
actor SystemFMBackend: FMBackend {
    private var prepared: (instructions: String, session: LanguageModelSession)?

    private static func makeSession(instructions: String) -> LanguageModelSession {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: instructions)
    }

    func isAvailable() async -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    func unavailabilityReason() async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady):
            return "Apple Intelligence model is downloading — available soon"
        case .unavailable(let other):
            return "Unavailable: \(String(describing: other))"
        }
    }

    func prewarm(instructions: String) async {
        let session = Self.makeSession(instructions: instructions)
        session.prewarm()
        prepared = (instructions, session)
    }

    func respond(instructions: String, prompt: String, temperature: Double) async throws -> String {
        let session: LanguageModelSession
        if let p = prepared, p.instructions == instructions, !p.session.isResponding {
            session = p.session
        } else {
            session = Self.makeSession(instructions: instructions)
        }
        prepared = nil
        defer { // Prepare the next one so the following dictation gets a warm start.
            let next = Self.makeSession(instructions: instructions)
            next.prewarm()
            prepared = (instructions, next)
        }
        do {
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(temperature: temperature))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:            throw CleanupError.refused
            case .assetsUnavailable:                       throw CleanupError.unavailable
            case .exceededContextWindowSize:               throw CleanupError.badResponse("context window exceeded")
            case .rateLimited, .concurrentRequests:        throw CleanupError.unavailable
            case .unsupportedGuide, .unsupportedLanguageOrLocale, .decodingFailure:
                throw CleanupError.badResponse(String(describing: error))
            @unknown default:                              throw CleanupError.badResponse(String(describing: error))
            }
        }
    }
}
