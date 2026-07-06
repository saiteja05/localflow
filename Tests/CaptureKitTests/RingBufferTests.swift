import Testing
@testable import CaptureKit

struct RingBufferTests {
    @Test func underfilledSnapshotReturnsWhatWasWritten() {
        var rb = RingBuffer(capacity: 8)
        rb.write([1, 2, 3])
        #expect(rb.snapshot() == [1, 2, 3])
    }
    @Test func overflowKeepsNewestInOrder() {
        var rb = RingBuffer(capacity: 4)
        rb.write([1, 2, 3])
        rb.write([4, 5, 6])
        #expect(rb.snapshot() == [3, 4, 5, 6])
    }
    @Test func writeLargerThanCapacityKeepsTail() {
        var rb = RingBuffer(capacity: 3)
        rb.write([1, 2, 3, 4, 5])
        #expect(rb.snapshot() == [3, 4, 5])
    }
    @Test func emptyBufferSnapshotsEmpty() {
        #expect(RingBuffer(capacity: 4).snapshot().isEmpty)
    }
}
