import Foundation
import Testing
@testable import Persistence
import CleanupKit

struct DictionaryStoreTests {
    @Test func startsEmptyAndPersists() {
        let dir = tempDir()
        let store = DictionaryStore(directory: dir)
        #expect(store.vocabulary.isEmpty && store.replacements.isEmpty)
        store.addVocabulary("Kubernetes")
        store.addReplacement(Replacement(spoken: "local flow", written: "LocalFlow"))
        let reloaded = DictionaryStore(directory: dir)
        #expect(reloaded.vocabulary == ["Kubernetes"])
        #expect(reloaded.replacements == [Replacement(spoken: "local flow", written: "LocalFlow")])
    }
    @Test func vocabularyDeduplicatesCaseInsensitively() {
        let store = DictionaryStore(directory: tempDir())
        store.addVocabulary("Kubernetes")
        store.addVocabulary("kubernetes")
        #expect(store.vocabulary.count == 1)
    }
    @Test func removeWorks() {
        let store = DictionaryStore(directory: tempDir())
        store.addVocabulary("Zig")
        store.removeVocabulary("Zig")
        #expect(store.vocabulary.isEmpty)
    }
    @Test func exportImportRoundTrips() throws {
        let a = DictionaryStore(directory: tempDir())
        a.addVocabulary("Kubernetes")
        a.addReplacement(Replacement(spoken: "eng standup", written: "Engineering Standup"))
        let b = DictionaryStore(directory: tempDir())
        try b.importData(a.exportData())
        #expect(b.vocabulary == a.vocabulary)
        #expect(b.replacements == a.replacements)
    }
    @Test func importOfGarbageThrowsAndLeavesStoreIntact() {
        let store = DictionaryStore(directory: tempDir())
        store.addVocabulary("Keep")
        #expect(throws: (any Error).self) { try store.importData(Data("nope".utf8)) }
        #expect(store.vocabulary == ["Keep"])
    }
}
