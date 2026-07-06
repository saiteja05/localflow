/// Fixed-capacity float ring buffer for the ~0.5s pre-roll that prevents
/// first-word clipping (spec §2). Not thread-safe; owner synchronizes.
public struct RingBuffer: Sendable {
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = false
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: 0, count: self.capacity)
    }

    public mutating func write(_ samples: [Float]) {
        for s in samples.suffix(capacity) {
            storage[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
            if writeIndex == 0 { filled = true }
        }
        if samples.count >= capacity { filled = true }
    }

    public func snapshot() -> [Float] {
        if !filled { return Array(storage[0..<writeIndex]) }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }
}
