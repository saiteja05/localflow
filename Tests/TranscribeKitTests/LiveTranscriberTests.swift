import Foundation
import Testing
@testable import TranscribeKit
import CaptureKit

struct LiveTranscriberTests {
    /// Real progressive SpeechAnalyzer session fed the fixture in live-sized
    /// chunks. Soft-skips when the en-US asset isn't installed.
    @Test func streamsIncrementalUpdatesFromChunks() async throws {
        let live = SystemLiveTranscriber(locale: Locale(identifier: "en_US"))
        guard await live.isReady() else {
            print("SKIP: system speech model not installed"); return
        }
        let audio = try Fixture.hello()
        let (chunks, feeder) = AsyncStream.makeStream(of: [Float].self)
        let updatesStream = await live.startSession(chunks: chunks)

        // Feed ~128ms chunks with small gaps, like the live mic tap does.
        let collector = Task { () -> [LiveUpdate] in
            var seen: [LiveUpdate] = []
            for await update in updatesStream { seen.append(update) }
            return seen
        }
        let chunkSize = 2048
        for start in stride(from: 0, to: audio.samples.count, by: chunkSize) {
            let end = min(start + chunkSize, audio.samples.count)
            feeder.yield(Array(audio.samples[start..<end]))
            try? await Task.sleep(for: .milliseconds(10))
        }
        feeder.finish()
        let updates = await collector.value

        #expect(updates.count >= 2, "expected incremental updates, got \(updates.count)")
        let combined = updates.last?.displayText.lowercased() ?? ""
        #expect(combined.contains("hello"))
    }
}

struct LocaleResolutionTests {
    /// Regression: en_US@rg=inzzzz (US English, India region override) must
    /// resolve to the installed en-US asset instead of silently failing.
    @Test func regionOverrideLocaleResolvesToInstalledAsset() async {
        let live = SystemLiveTranscriber(locale: Locale(identifier: "en_US@rg=inzzzz"))
        let plain = SystemLiveTranscriber(locale: Locale(identifier: "en_US"))
        guard await plain.isReady() else {
            print("SKIP: en-US speech asset not installed"); return
        }
        #expect(await live.isReady() == true)

        let batch = SystemTranscriber(locale: Locale(identifier: "en_US@rg=inzzzz"))
        #expect(await batch.isReady() == true)
    }
}
