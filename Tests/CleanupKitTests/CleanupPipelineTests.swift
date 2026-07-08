import Foundation
import Testing
@testable import CleanupKit

/// Configurable fake provider.
final class FakeProvider: CleanupProvider, @unchecked Sendable {
    let id: String
    var available = true
    var result: Result<String, CleanupError> = .success("LLM CLEANED")
    var delay: TimeInterval = 0
    private(set) var cleanCallCount = 0
    init(id: String) { self.id = id }
    func isAvailable() async -> Bool { available }
    func clean(_ text: String, options: CleanupOptions) async throws -> String {
        cleanCallCount += 1
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try result.get()
    }
}

struct CleanupPipelineTests {
    let replacements = [Replacement(spoken: "local flow", written: "LocalFlow")]

    func options(_ level: CleanupLevel) -> CleanupOptions {
        CleanupOptions(level: level, vocabulary: [])
    }

    @Test func offAppliesOnlyReplacements() async {
        let p = CleanupPipeline(providers: [FakeProvider(id: "apple-fm")])
        let r = await p.process("um the local flow app", options: options(.off), replacements: replacements)
        #expect(r.text == "um the LocalFlow app")   // fillers kept: raw mode
        #expect(r.providerID == "raw")
    }

    @Test func lightRunsRulesAndReplacementsNoLLM() async {
        let fake = FakeProvider(id: "apple-fm")
        let p = CleanupPipeline(providers: [fake])
        let r = await p.process("um the local flow app", options: options(.light), replacements: replacements)
        #expect(r.text == "The LocalFlow app")
        #expect(r.providerID == "rules")
        #expect(fake.cleanCallCount == 0)
    }

    @Test func standardUsesFirstAvailableProvider() async {
        let unavailable = FakeProvider(id: "apple-fm"); unavailable.available = false
        let ollama = FakeProvider(id: "ollama"); ollama.result = .success("Ollama cleaned local flow.")
        let p = CleanupPipeline(providers: [unavailable, ollama])
        let r = await p.process("raw", options: options(.standard), replacements: replacements)
        #expect(r.text == "Ollama cleaned LocalFlow.")   // replacements post-LLM
        #expect(r.providerID == "ollama")
        #expect(unavailable.cleanCallCount == 0)
    }

    @Test func providerErrorFallsThroughToNext() async {
        let failing = FakeProvider(id: "apple-fm"); failing.result = .failure(.refused)
        let ollama = FakeProvider(id: "ollama")
        let p = CleanupPipeline(providers: [failing, ollama])
        let r = await p.process("raw", options: options(.standard), replacements: [])
        #expect(r.providerID == "ollama")
    }

    @Test func allProvidersFailingFallsBackToRules() async {
        let a = FakeProvider(id: "apple-fm"); a.result = .failure(.unavailable)
        let b = FakeProvider(id: "ollama"); b.available = false
        let p = CleanupPipeline(providers: [a, b])
        let r = await p.process("um hello there", options: options(.standard), replacements: [])
        #expect(r.text == "Hello there")
        #expect(r.providerID == "rules")
    }

    @Test func slowProviderTimesOutAndFallsThrough() async {
        let slow = FakeProvider(id: "apple-fm"); slow.delay = 5
        let fast = FakeProvider(id: "ollama")
        let p = CleanupPipeline(providers: [slow, fast], timeout: 0.2)
        let start = Date()
        let r = await p.process("raw", options: options(.standard), replacements: [])
        #expect(r.providerID == "ollama")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func llmReturningEmptyFallsThrough() async {
        let empty = FakeProvider(id: "apple-fm"); empty.result = .success("   ")
        let p = CleanupPipeline(providers: [empty])
        let r = await p.process("um hello", options: options(.standard), replacements: [])
        #expect(r.text == "Hello")
        #expect(r.providerID == "rules")
    }

    @Test func emptyInputShortCircuits() async {
        let fake = FakeProvider(id: "apple-fm")
        let p = CleanupPipeline(providers: [fake])
        let r = await p.process("", options: options(.standard), replacements: replacements)
        #expect(r.text == "" && r.providerID == "raw")
        #expect(fake.cleanCallCount == 0)
    }

    @Test func transformUsesFirstAvailableProviderAndFallsThrough() async {
        final class EditProvider: CleanupProvider, @unchecked Sendable {
            let id: String
            var available = true
            var result: Result<String, CleanupError> = .success("EDITED")
            init(id: String) { self.id = id }
            func isAvailable() async -> Bool { available }
            func clean(_ text: String, options: CleanupOptions) async throws -> String { text }
            func transform(_ text: String, instruction: String) async throws -> String {
                try result.get()
            }
        }
        let failing = EditProvider(id: "apple-fm"); failing.result = .failure(.refused)
        let working = EditProvider(id: "ollama")
        let p = CleanupPipeline(providers: [failing, working])
        #expect(await p.transform("text", instruction: "do it") == "EDITED")

        let none = CleanupPipeline(providers: [])
        #expect(await none.transform("text", instruction: "do it") == nil)
    }

    @Test func transformRejectsPreambleViolatingOutputAndFallsThrough() async {
        final class EditProvider: CleanupProvider, @unchecked Sendable {
            let id: String
            var result: Result<String, CleanupError>
            init(id: String, result: Result<String, CleanupError>) { self.id = id; self.result = result }
            func isAvailable() async -> Bool { true }
            func clean(_ text: String, options: CleanupOptions) async throws -> String { text }
            func transform(_ text: String, instruction: String) async throws -> String { try result.get() }
        }
        // Reproduces the real incident: model narrates a fabricated,
        // unrelated reply instead of editing the actual selection.
        let hallucinating = EditProvider(id: "apple-fm", result: .success(
            "Sure, here is a softer version of the transcript: 'Hello everyone, my name is...'"))
        let working = EditProvider(id: "ollama", result: .success(
            "Hi @jyan, great news — both items are done!"))
        let p = CleanupPipeline(providers: [hallucinating, working])
        let edited = await p.transform(
            "Hi @jyan, great news both items we discussed are done!",
            instruction: "make the tone softer")
        #expect(edited == "Hi @jyan, great news — both items are done!")

        let onlyHallucinating = CleanupPipeline(providers: [hallucinating])
        #expect(await onlyHallucinating.transform("text", instruction: "do it") == nil)
    }

    @Test func transformDefaultImplementationOptsOut() async {
        // A provider without transform support (protocol default) is skipped.
        let rulesOnly = FakeProvider(id: "fake")   // FakeProvider has no transform override
        let p = CleanupPipeline(providers: [rulesOnly])
        #expect(await p.transform("text", instruction: "do it") == nil)
    }

    @Test func processRejectsPreambleViolatingCleanupAndFallsThrough() async {
        let hallucinating = FakeProvider(id: "apple-fm")
        hallucinating.result = .success("Sure, here is the cleaned text: something unrelated")
        let working = FakeProvider(id: "ollama")
        working.result = .success("Ollama cleaned local flow.")
        let p = CleanupPipeline(providers: [hallucinating, working])
        let r = await p.process("raw", options: options(.standard), replacements: replacements)
        #expect(r.text == "Ollama cleaned LocalFlow.")
        #expect(r.providerID == "ollama")
    }

    @Test func processFallsBackToRulesWhenOnlyProviderViolatesPreamble() async {
        let hallucinating = FakeProvider(id: "apple-fm")
        hallucinating.result = .success("Sure, here is the cleaned text: something unrelated")
        let p = CleanupPipeline(providers: [hallucinating])
        let r = await p.process("um hello there", options: options(.standard), replacements: [])
        #expect(r.text == "Hello there")
        #expect(r.providerID == "rules")
    }

    @Test func processStripsWrappingQuotesFromProviderOutput() async {
        let quoted = FakeProvider(id: "apple-fm")
        quoted.result = .success("\"Hello there, team.\"")
        let p = CleanupPipeline(providers: [quoted])
        let r = await p.process("raw", options: options(.standard), replacements: [])
        #expect(r.text == "Hello there, team.")
        #expect(r.providerID == "apple-fm")
    }

    @Test func transformStripsWrappingQuotesFromProviderOutput() async {
        final class EditProvider: CleanupProvider, @unchecked Sendable {
            let id: String
            var result: Result<String, CleanupError>
            init(id: String, result: Result<String, CleanupError>) { self.id = id; self.result = result }
            func isAvailable() async -> Bool { true }
            func clean(_ text: String, options: CleanupOptions) async throws -> String { text }
            func transform(_ text: String, instruction: String) async throws -> String { try result.get() }
        }
        let quoted = EditProvider(id: "apple-fm", result: .success("'Hi team, edited!'"))
        let p = CleanupPipeline(providers: [quoted])
        let edited = await p.transform("text", instruction: "do it")
        #expect(edited == "Hi team, edited!")
    }

    @Test func fillerOnlyInputLegitimatelyCleansToEmpty() async {
        // Not a contract violation: rules removing everything IS the feature.
        // FlowController maps empty cleaned text to "Didn't catch that" (Task 17).
        let p = CleanupPipeline(providers: [])
        let r = await p.process("um uh", options: options(.light), replacements: [])
        #expect(r.text == "" && r.providerID == "rules")
    }
}
