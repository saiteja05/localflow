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
}
