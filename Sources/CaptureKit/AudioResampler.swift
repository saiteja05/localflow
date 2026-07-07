import AVFoundation

/// Converts arbitrary input PCM to the canonical 16 kHz mono Float32.
public final class AudioResampler {
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioData.sampleRate,
        channels: 1, interleaved: false)!

    private let converter: AVAudioConverter
    private var pending: AVAudioPCMBuffer?

    public init?(inputFormat: AVAudioFormat) {
        guard let c = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else { return nil }
        converter = c
    }

    /// Streaming-safe: keeps converter state across calls (use .noDataNow, never .endOfStream).
    public func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        pending = buffer
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity)
        else { return [] }
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { [weak self] _, inputStatus in
            if let b = self?.pending {
                self?.pending = nil
                inputStatus.pointee = .haveData
                return b
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// One-shot conversion for whole files (flushes with .endOfStream).
    public static func convertAll(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var supplied = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
