import AVFoundation
import Testing
@testable import CaptureKit

struct AudioResamplerTests {
    @Test func oneShotConverts48kStereoTo16kMono() {
        let input = makeSineBuffer(sampleRate: 48_000, channels: 2)
        let out = AudioResampler.convertAll(input)
        // 0.5s of audio -> ~8000 samples at 16k (converter latency tolerance ±256)
        #expect(abs(out.count - 8000) < 256)
        #expect(out.contains { abs($0) > 0.1 })          // signal survived
        #expect(out.allSatisfy { $0.isFinite })
    }
    @Test func streamingConversionAccumulatesAcrossCalls() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let resampler = AudioResampler(inputFormat: format)!
        var total: [Float] = []
        for _ in 0..<4 {
            total += resampler.process(makeSineBuffer(sampleRate: 48_000, channels: 1))
        }
        // 4 × 0.5s -> ~32000 samples at 16k
        #expect(abs(total.count - 32_000) < 1024)
    }
}
