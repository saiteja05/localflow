import Foundation
import Testing
@testable import TranscribeKit
import CaptureKit

struct ParakeetTranscriberTests {
    @Test func tooShortAudioReturnsEmptyTranscriptNotError() async throws {
        let t = ParakeetTranscriber()
        guard await t.isReady() else { print("SKIP: Parakeet model not downloaded"); return }
        let blip = AudioData(samples: Array(repeating: 0, count: 1000))  // < 0.3s
        let result = try await t.transcribe(blip)
        #expect(result.text.isEmpty)
    }

    /// Integration: runs only when the ~600MB model is already cached locally.
    /// First-time download happens via `localflow-cli transcribe` or app onboarding.
    @Test func transcribesFixtureSpeech() async throws {
        guard ParakeetTranscriber.modelIsDownloaded else {
            print("SKIP: Parakeet model not downloaded"); return
        }
        let t = ParakeetTranscriber()
        try await t.prepare(progress: nil)
        let result = try await t.transcribe(try Fixture.hello())
        let lower = result.text.lowercased()
        #expect(lower.contains("hello"))
        #expect(lower.contains("test"))
    }

    @Test func routerFallsBackWhenPrimaryNotReady() async throws {
        struct NeverReady: Transcriber {
            func isReady() async -> Bool { false }
            func transcribe(_ audio: AudioData) async throws -> Transcript {
                throw TranscriptionError.modelUnavailable
            }
        }
        struct AlwaysReady: Transcriber {
            func isReady() async -> Bool { true }
            func transcribe(_ audio: AudioData) async throws -> Transcript {
                Transcript(text: "fallback", languageHint: nil)
            }
        }
        let router = TranscriberRouter(primary: NeverReady(), fallback: AlwaysReady())
        let out = try await router.transcribe(AudioData(samples: Array(repeating: 0, count: 8000)))
        #expect(out.text == "fallback")
        #expect(await router.isReady() == true)
    }
}
