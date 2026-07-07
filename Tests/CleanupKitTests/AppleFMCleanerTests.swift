import Testing
@testable import CleanupKit

final class MockFMBackend: FMBackend, @unchecked Sendable {
    var available = true
    var reason: String?
    var response: Result<String, CleanupError> = .success("Cleaned.")
    private(set) var lastInstructions: String?
    private(set) var lastPrompt: String?
    private(set) var prewarmCount = 0
    func isAvailable() async -> Bool { available }
    func unavailabilityReason() async -> String? { available ? nil : (reason ?? "off") }
    func respond(instructions: String, prompt: String, temperature: Double) async throws -> String {
        lastInstructions = instructions
        lastPrompt = prompt
        return try response.get()
    }
    func prewarm(instructions: String) async { prewarmCount += 1 }
}

struct AppleFMCleanerTests {
    let options = CleanupOptions(level: .standard, vocabulary: ["LocalFlow"])

    @Test func buildsPromptFromPromptBuilder() async throws {
        let backend = MockFMBackend()
        let cleaner = AppleFMCleaner(backend: backend)
        _ = try await cleaner.clean("um hello", options: options)
        #expect(backend.lastInstructions == PromptBuilder.instructions(level: .standard,
                                                                       vocabulary: ["LocalFlow"]))
        #expect(backend.lastPrompt == PromptBuilder.userPrompt(for: "um hello"))
    }
    @Test func trimsAndStripsWrappingQuotes() async throws {
        let backend = MockFMBackend()
        backend.response = .success("  \"Hello there.\"  ")
        let cleaner = AppleFMCleaner(backend: backend)
        #expect(try await cleaner.clean("x", options: options) == "Hello there.")
    }
    @Test func emptyModelOutputThrowsBadResponse() async {
        let backend = MockFMBackend()
        backend.response = .success("   ")
        let cleaner = AppleFMCleaner(backend: backend)
        await #expect(throws: CleanupError.badResponse("empty model output")) {
            _ = try await cleaner.clean("x", options: options)
        }
    }
    @Test func backendErrorsPropagate() async {
        let backend = MockFMBackend()
        backend.response = .failure(.refused)
        let cleaner = AppleFMCleaner(backend: backend)
        await #expect(throws: CleanupError.refused) {
            _ = try await cleaner.clean("x", options: options)
        }
    }
    @Test func availabilityDelegatesToBackend() async {
        let backend = MockFMBackend()
        backend.available = false
        #expect(await AppleFMCleaner(backend: backend).isAvailable() == false)
    }
    @Test func unavailabilityReasonSurfacesFromBackend() async {
        let backend = MockFMBackend()
        backend.available = false
        backend.reason = "Turn on Apple Intelligence in System Settings"
        let cleaner = AppleFMCleaner(backend: backend)
        #expect(await cleaner.unavailabilityReason() == "Turn on Apple Intelligence in System Settings")
        backend.available = true
        #expect(await cleaner.unavailabilityReason() == nil)
    }
    @Test func prewarmForwardsBuiltInstructions() async {
        let backend = MockFMBackend()
        await AppleFMCleaner(backend: backend).prewarm(options: options)
        #expect(backend.prewarmCount == 1)
    }
}

import FoundationModels

/// Real on-device model. Runs only where Apple Intelligence is on (skipped in CI).
@Suite struct AppleFMIntegrationTests {
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func realModelCleansDictatedText() async throws {
        let cleaner = AppleFMCleaner()
        let out = try await cleaner.clean(
            "um so i think we should uh no wait we should definitely ship on friday",
            options: CleanupOptions(level: .standard, vocabulary: []))
        #expect(!out.isEmpty)
        #expect(!out.lowercased().contains("um"))
        #expect(out.lowercased().contains("friday"))
    }
}
