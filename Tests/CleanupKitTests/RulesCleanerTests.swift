import Testing
@testable import CleanupKit

struct RulesCleanerTests {
    @Test func stripsStandaloneFillers() {
        #expect(RulesCleaner.clean("um I think uh we should ship") == "I think we should ship")
    }
    @Test func stripsFillersCaseInsensitively() {
        #expect(RulesCleaner.clean("Um, let's go") == "Let's go")
    }
    @Test func stripsFillerWithTrailingComma() {
        #expect(RulesCleaner.clean("so, um, the plan works") == "so, the plan works")
    }
    @Test func stripsYouKnowAtClauseBoundary() {
        #expect(RulesCleaner.clean("it works, you know, most days") == "it works, most days")
        #expect(RulesCleaner.clean("You know, it works") == "It works")
    }
    @Test func keepsYouKnowMidClause() {
        #expect(RulesCleaner.clean("do you know the answer") == "do you know the answer")
    }
    @Test func collapsesImmediateWordRepetition() {
        #expect(RulesCleaner.clean("the the plan is is ready") == "the plan is ready")
    }
    @Test func repetitionCollapseIsCaseInsensitiveKeepsFirst() {
        #expect(RulesCleaner.clean("The the plan") == "The plan")
    }
    @Test func normalizesWhitespaceAndPunctuationSpacing() {
        #expect(RulesCleaner.clean("hello   world , again .") == "Hello world, again.")
    }
    @Test func capitalizesFirstLetter() {
        #expect(RulesCleaner.clean("hello there") == "Hello there")
    }
    @Test func doesNotAddTerminalPunctuation() {
        #expect(RulesCleaner.clean("quick search query") == "Quick search query")
    }
    @Test func emptyAndWhitespaceOnlyInputs() {
        #expect(RulesCleaner.clean("") == "")
        #expect(RulesCleaner.clean("   ") == "")
        #expect(RulesCleaner.clean("um uh") == "")
    }
    @Test func preservesMultiSentenceText() {
        #expect(RulesCleaner.clean("um okay. So the the deadline is friday.")
                == "Okay. So the deadline is friday.")
    }
}
