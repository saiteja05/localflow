import Foundation

/// Orchestrates: rules pass -> first working LLM provider (with timeout) -> replacements.
/// NEVER throws; provider (AI) failure can never yield less than the rules-cleaned
/// text (spec: never block insertion on AI failure). Filler-only input may
/// legitimately clean to empty — FlowController maps that to "Didn't catch that".
public struct CleanupPipeline: CleanupProcessing {
    private let providers: [any CleanupProvider]
    private let timeout: TimeInterval

    public init(providers: [any CleanupProvider], timeout: TimeInterval = 4) {
        self.providers = providers
        self.timeout = timeout
    }

    public func process(_ raw: String, options: CleanupOptions,
                        replacements: [Replacement]) async -> CleanupResult {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return CleanupResult(text: "", providerID: "raw") }

        func finish(_ text: String, _ providerID: String) -> CleanupResult {
            CleanupResult(text: ReplacementEngine.apply(replacements, to: text),
                          providerID: providerID)
        }

        switch options.level {
        case .off:
            return finish(trimmedRaw, "raw")
        case .light:
            return finish(RulesCleaner.clean(trimmedRaw), "rules")
        case .standard, .heavy:
            let ruled = RulesCleaner.clean(trimmedRaw)
            for provider in providers {
                guard await provider.isAvailable() else { continue }
                do {
                    let out = try await withTimeout(timeout) {
                        try await provider.clean(ruled, options: options)
                    }
                    let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { return finish(cleaned, provider.id) }
                } catch {
                    continue  // fall through to next provider (spec §5)
                }
            }
            return finish(ruled, "rules")
        }
    }
}

/// Races `work` against a deadline. Throws CleanupError.timedOut on expiry.
func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CleanupError.timedOut
        }
        guard let first = try await group.next() else { throw CleanupError.timedOut }
        group.cancelAll()
        return first
    }
}
