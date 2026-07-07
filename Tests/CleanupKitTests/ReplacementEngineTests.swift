import Testing
@testable import CleanupKit

struct ReplacementEngineTests {
    @Test func replacesWholeWordCaseInsensitively() {
        let r = [Replacement(spoken: "kubernetes", written: "Kubernetes")]
        #expect(ReplacementEngine.apply(r, to: "deploy to Kubernetes and kubernetes") ==
                "deploy to Kubernetes and Kubernetes")
    }
    @Test func replacesMultiWordPhrases() {
        let r = [Replacement(spoken: "eng standup", written: "Engineering Standup")]
        #expect(ReplacementEngine.apply(r, to: "join eng standup at 9") ==
                "join Engineering Standup at 9")
    }
    @Test func doesNotReplaceInsideWords() {
        let r = [Replacement(spoken: "cat", written: "CAT")]
        #expect(ReplacementEngine.apply(r, to: "concatenate the cat file") ==
                "concatenate the CAT file")
    }
    @Test func longestSpokenFormWinsWhenOverlapping() {
        let r = [Replacement(spoken: "sequel", written: "SQL"),
                 Replacement(spoken: "my sequel", written: "MySQL")]
        #expect(ReplacementEngine.apply(r, to: "use my sequel or sequel") == "use MySQL or SQL")
    }
    @Test func escapesRegexMetacharactersInSpokenForm() {
        let r = [Replacement(spoken: "c++", written: "C++")]
        #expect(ReplacementEngine.apply(r, to: "i like c++ a lot") == "i like C++ a lot")
    }
    @Test func emptyReplacementsIsIdentity() {
        #expect(ReplacementEngine.apply([], to: "hello") == "hello")
    }
}
