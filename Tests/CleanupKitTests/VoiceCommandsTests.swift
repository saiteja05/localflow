import Testing
@testable import CleanupKit

struct VoiceCommandsTests {
    @Test func discardsEverythingBeforeScratchThat() {
        #expect(VoiceCommandProcessor.apply("buy milk and eggs scratch that just bread") == "just bread")
    }
    @Test func discardsEverythingBeforeUndoThat() {
        #expect(VoiceCommandProcessor.apply("Meet at noon. Undo That. Meet at three") == "Meet at three")
    }
    @Test func doesNotFalsePositiveOnScratchedThat() {
        #expect(VoiceCommandProcessor.apply("we scratched that idea already") == "we scratched that idea already")
    }
    @Test func multipleDiscardsKeepOnlyTailAfterLast() {
        #expect(VoiceCommandProcessor.apply("add eggs scratch that add milk delete that add bread") == "add bread")
    }
    @Test func applyNeverTouchesFormattingPhrases() {
        #expect(VoiceCommandProcessor.apply("say new paragraph then continue") == "say new paragraph then continue")
    }
    @Test func applyFormattingConvertsNewParagraph() {
        #expect(VoiceCommandProcessor.applyFormatting("first point new paragraph second point") == "first point\n\nsecond point")
    }
    @Test func applyFormattingConvertsNewLine() {
        #expect(VoiceCommandProcessor.applyFormatting("item one. New Line item two") == "item one.\nitem two")
    }
}
