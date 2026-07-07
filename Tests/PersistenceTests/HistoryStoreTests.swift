import Foundation
import Testing
@testable import Persistence

struct HistoryStoreTests {
    func entry(_ n: Int) -> HistoryEntry {
        HistoryEntry(timestamp: Date(timeIntervalSince1970: Double(n)),
                     rawText: "raw \(n)", cleanedText: "clean \(n)",
                     appBundleID: "com.apple.Notes", providerID: "apple-fm")
    }
    @Test func addsAndPersists() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        store.add(entry(1)); store.add(entry(2))
        let reloaded = HistoryStore(directory: dir)
        #expect(reloaded.entries.count == 2)
        #expect(reloaded.entries.last?.cleanedText == "clean 2")
    }
    @Test func retentionTrimsOldest() {
        let store = HistoryStore(directory: tempDir())
        store.retentionLimit = 3
        for n in 1...5 { store.add(entry(n)) }
        #expect(store.entries.map(\.rawText) == ["raw 3", "raw 4", "raw 5"])
    }
    @Test func disabledStoreRecordsNothing() {
        let store = HistoryStore(directory: tempDir())
        store.isEnabled = false
        store.add(entry(1))
        #expect(store.entries.isEmpty)
    }
    @Test func clearRemovesEverythingIncludingOnDisk() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        store.add(entry(1))
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(HistoryStore(directory: dir).entries.isEmpty)
    }
    @Test func corruptLinesAreSkipped() throws {
        let dir = tempDir()
        let good = try String(data: JSONEncoder().encode(entry(1)), encoding: .utf8)!
        try Data("garbage\n\(good)\n".utf8).write(to: dir.appending(path: "history.jsonl"))
        #expect(HistoryStore(directory: dir).entries.count == 1)
    }
}
