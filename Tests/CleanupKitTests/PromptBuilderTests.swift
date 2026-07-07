import Testing
@testable import CleanupKit

struct PromptBuilderTests {
    @Test func standardInstructionsContainCoreDirectives() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: [])
        #expect(i.contains("punctuation"))
        #expect(i.contains("filler"))
        #expect(i.contains("self-correction") || i.contains("no wait"))
        #expect(i.contains("same language"))
        #expect(i.contains("Output only"))
        #expect(!i.contains("grammar"))          // heavy-only directive
    }
    @Test func heavyInstructionsAddGrammarAndLists() {
        let i = PromptBuilder.instructions(level: .heavy, vocabulary: [])
        #expect(i.contains("grammar"))
        #expect(i.contains("list"))
    }
    @Test func vocabularyIsEmbedded() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: ["Kubernetes", "Boddapati"])
        #expect(i.contains("Kubernetes, Boddapati"))
    }
    @Test func noVocabularySectionWhenEmpty() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: [])
        #expect(!i.contains("Vocabulary"))
    }
    @Test func userPromptWrapsTranscript() {
        #expect(PromptBuilder.userPrompt(for: "hello world") == "Transcript:\nhello world")
    }

    // MARK: tone

    @Test func neutralToneAddsNoDirective() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: [], tone: .neutral)
        #expect(!i.contains("tone"))
        // Default parameter behaves identically:
        #expect(i == PromptBuilder.instructions(level: .standard, vocabulary: []))
    }
    @Test func casualToneAddsDirective() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: [], tone: .casual)
        #expect(i.contains("casual, conversational tone"))
    }
    @Test func formalToneAddsDirective() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: [], tone: .formal)
        #expect(i.contains("formal, professional tone"))
    }
    @Test func toneDirectiveComesBeforeOutputOnlyLine() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: ["X"], tone: .formal)
        let tonePos = i.range(of: "formal, professional")!.lowerBound
        let outputPos = i.range(of: "Output only")!.lowerBound
        #expect(tonePos < outputPos)
    }
}
