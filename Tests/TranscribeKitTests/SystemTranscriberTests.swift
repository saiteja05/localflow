import Foundation
import Testing
@testable import TranscribeKit
import CaptureKit

enum Fixture {
    static func hello() throws -> AudioData {
        let url = Bundle.module.url(forResource: "hello", withExtension: "wav",
                                    subdirectory: "Fixtures")!
        return try AudioFileLoader.load(url: url)
    }
}

struct SystemTranscriberTests {
    @Test func transcriptTypeRoundTrips() {
        let t = Transcript(text: "hi", languageHint: "en-US")
        #expect(t.text == "hi" && t.languageHint == "en-US")
    }

    /// Integration: needs the en-US system speech asset. Soft-skips when absent
    /// (CI images may not have it); downloads on first local run via prepare().
    @Test func transcribesFixtureSpeech() async throws {
        let transcriber = SystemTranscriber(locale: Locale(identifier: "en_US"))
        do { try await transcriber.prepare() } catch {
            print("SKIP: system speech model unavailable: \(error)")
            return
        }
        guard await transcriber.isReady() else {
            print("SKIP: system speech model not installed")
            return
        }
        let result = try await transcriber.transcribe(Fixture.hello())
        let lower = result.text.lowercased()
        #expect(lower.contains("hello"))
        #expect(lower.contains("test"))
    }

    @Test func emptyAudioReturnsEmptyTranscript() async throws {
        let transcriber = SystemTranscriber(locale: Locale(identifier: "en_US"))
        guard await transcriber.isReady() else {
            print("SKIP: system speech model not installed")
            return
        }
        let silent = AudioData(samples: Array(repeating: 0, count: 16_000))
        let result = try await transcriber.transcribe(silent)
        #expect(result.text.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
