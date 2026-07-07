import Foundation

/// Canonical audio interchange: 16 kHz mono Float32 (spec Global Constraints).
public struct AudioData: Sendable, Equatable {
    public static let sampleRate: Double = 16_000
    public var samples: [Float]
    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public init(samples: [Float]) { self.samples = samples }
}

public protocol AudioCapturing: Sendable {
    func startCapture() throws
    func stopCapture() async -> AudioData
    func cancelCapture()
    var levels: AsyncStream<Float> { get }
    /// Fresh per-dictation stream of 16 kHz mono chunks, live while capturing.
    /// Call after startCapture(); the stream finishes when capture stops.
    func makeLiveChunkStream() -> AsyncStream<[Float]>
}

public extension AudioCapturing {
    /// Capturers without live streaming yield an immediately-finished stream.
    func makeLiveChunkStream() -> AsyncStream<[Float]> {
        AsyncStream { $0.finish() }
    }
}
