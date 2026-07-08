import Testing
@testable import InsertKit

struct LiveTypeDiffTests {
    @Test func pureAppendNeedsNoBackspaces() {
        let d = LiveTypeDiff.compute(from: "hello", to: "hello world")
        #expect(d.backspaces == 0)
        #expect(d.suffix == " world")
    }
    @Test func partialCorrectionBackspacesOnlyTheDivergentTail() {
        let d = LiveTypeDiff.compute(from: "hello wrold", to: "hello world")
        #expect(d.backspaces == 4)
        #expect(d.suffix == "orld")
    }
    @Test func fullReplaceBackspacesEverything() {
        let d = LiveTypeDiff.compute(from: "foo", to: "bar")
        #expect(d.backspaces == 3)
        #expect(d.suffix == "bar")
    }
    @Test func emojiClusterNotSplitOnAppend() {
        let d = LiveTypeDiff.compute(from: "👩‍👩‍👧‍👦", to: "👩‍👩‍👧‍👦!")
        #expect(d.backspaces == 0)
        #expect(d.suffix == "!")
    }
    @Test func differingEmojiClusterReplacedAsWholeUnit() {
        let d = LiveTypeDiff.compute(from: "😀", to: "😃")
        #expect(d.backspaces == 1)
        #expect(d.suffix == "😃")
    }
    @Test func identicalStringsNeedNoWork() {
        let d = LiveTypeDiff.compute(from: "same", to: "same")
        #expect(d.backspaces == 0)
        #expect(d.suffix == "")
    }
    @Test func emptyOldIsPureAppend() {
        let d = LiveTypeDiff.compute(from: "", to: "hi")
        #expect(d.backspaces == 0)
        #expect(d.suffix == "hi")
    }
    @Test func emptyNewClearsEverything() {
        let d = LiveTypeDiff.compute(from: "hi", to: "")
        #expect(d.backspaces == 2)
        #expect(d.suffix == "")
    }
}
