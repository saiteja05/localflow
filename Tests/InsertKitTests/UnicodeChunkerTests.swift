import Testing
@testable import InsertKit

struct UnicodeChunkerTests {
    @Test func shortStringIsSingleChunk() {
        #expect(UnicodeChunker.chunks(of: "hello") == ["hello"])
    }
    @Test func chunksRespectUTF16Limit() {
        let text = String(repeating: "a", count: 50)
        let chunks = UnicodeChunker.chunks(of: text, maxUTF16PerChunk: 18)
        #expect(chunks.allSatisfy { $0.utf16.count <= 18 })
        #expect(chunks.joined() == text)
    }
    @Test func neverSplitsEmoji() {
        let text = String(repeating: "👩‍👩‍👧‍👦", count: 10)   // 11 UTF-16 units each
        let chunks = UnicodeChunker.chunks(of: text, maxUTF16PerChunk: 18)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 18 })
    }
    @Test func emptyStringYieldsNoChunks() {
        #expect(UnicodeChunker.chunks(of: "") == [])
    }
}
