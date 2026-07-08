import Testing
@testable import CleanupKit

struct ResponseGuardTests {
    @Test func compliantTextPasses() {
        #expect(ResponseGuard.isCompliant("Hi team, both items are done!"))
    }

    @Test func preamblePrefixesAreRejected() {
        #expect(!ResponseGuard.isCompliant("Sure, here is a softer version: ..."))
        #expect(!ResponseGuard.isCompliant("Certainly! Here you go."))
        #expect(!ResponseGuard.isCompliant("Of course, happy to help."))
        #expect(!ResponseGuard.isCompliant("Here's the edited text."))
        #expect(!ResponseGuard.isCompliant("Okay, here is the result."))
    }

    @Test func preambleCheckIsCaseInsensitive() {
        #expect(!ResponseGuard.isCompliant("SURE, here you go."))
    }

    @Test func stripWrappingDoubleQuotes() {
        #expect(ResponseGuard.stripWrappingQuotes("\"Hi team, done!\"") == "Hi team, done!")
    }

    @Test func stripWrappingSingleQuotes() {
        #expect(ResponseGuard.stripWrappingQuotes("'Hi team, done!'") == "Hi team, done!")
    }

    @Test func stripWrappingCurlyQuotes() {
        #expect(ResponseGuard.stripWrappingQuotes("\u{201C}Hi team, done!\u{201D}") == "Hi team, done!")
    }

    @Test func unwrappedTextIsUnchanged() {
        #expect(ResponseGuard.stripWrappingQuotes("Hi team, done!") == "Hi team, done!")
    }

    @Test func mismatchedQuotesAreNotStripped() {
        #expect(ResponseGuard.stripWrappingQuotes("\"Hi team, done!'") == "\"Hi team, done!'")
    }

    @Test func internalQuotesAreNotStripped() {
        #expect(ResponseGuard.stripWrappingQuotes("She said \"hi\" to the team") == "She said \"hi\" to the team")
    }
}
