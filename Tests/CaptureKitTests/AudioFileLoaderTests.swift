import AVFoundation
import Testing
@testable import CaptureKit

/// 0.5s sine at `hz` in the given format.
func makeSineBuffer(sampleRate: Double, channels: AVAudioChannelCount, hz: Double = 440) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let frames = AVAudioFrameCount(sampleRate / 2)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<Int(channels) {
        let ptr = buf.floatChannelData![ch]
        for i in 0..<Int(frames) {
            ptr[i] = sinf(Float(2.0 * .pi * hz * Double(i) / sampleRate)) * 0.5
        }
    }
    return buf
}

struct AudioFileLoaderTests {
    @Test func loadsWavAndResamplesTo16k() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "loader-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = makeSineBuffer(sampleRate: 44_100, channels: 1)
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)

        let audio = try AudioFileLoader.load(url: url)
        #expect(abs(audio.duration - 0.5) < 0.05)
        #expect(audio.samples.contains { abs($0) > 0.1 })
    }
    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            _ = try AudioFileLoader.load(url: URL(filePath: "/nonexistent/x.wav"))
        }
    }
}
