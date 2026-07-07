@preconcurrency import AVFoundation   // silences Sendable warnings on AVAudioPCMBuffer
import Foundation
import Speech
import CaptureKit

/// One incremental snapshot of an in-progress dictation.
public struct LiveUpdate: Sendable, Equatable {
    /// Text the engine has locked in (never revised again).
    public let finalizedText: String
    /// Trailing hypothesis that may still change.
    public let volatileText: String
    public var displayText: String {
        volatileText.isEmpty ? finalizedText
            : finalizedText.isEmpty ? volatileText
            : finalizedText + " " + volatileText
    }
    public init(finalizedText: String, volatileText: String) {
        self.finalizedText = finalizedText
        self.volatileText = volatileText
    }
}

/// Streams incremental transcript updates from live audio chunks. Used for
/// the HUD preview only — the inserted text always comes from the batch
/// pass (full context, better accuracy, tone + dictionary applied).
public protocol LiveTranscribing: Sendable {
    func isReady() async -> Bool
    /// Consumes `chunks` (16 kHz mono Float32) until the stream finishes;
    /// returns updates. Ends when the chunk stream ends or endSession() runs.
    func startSession(chunks: AsyncStream<[Float]>) async -> AsyncStream<LiveUpdate>
    func endSession() async
}

/// SpeechAnalyzer progressive transcription (macOS 26). Near-zero first-word
/// latency and zero extra downloads — Parakeet's only streaming mode needs
/// ~13s of audio before its first hypothesis, so Apple's engine previews and
/// Parakeet finalizes.
public actor SystemLiveTranscriber: LiveTranscribing {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var pumpTask: Task<Void, Never>?

    public init(locale: Locale = Locale(identifier: "en_US")) {
        self.locale = locale
    }

    /// Region-override locales (e.g. en_US@rg=inzzzz -> "en-US-u-rg-inzzzz")
    /// fail exact-identifier checks against the plain "en-US" asset — always
    /// resolve through Apple's equivalence API first.
    private func resolvedLocale() async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
    }

    public func isReady() async -> Bool {
        let resolved = await resolvedLocale()
        let installed = await SpeechTranscriber.installedLocales
        return installed.map { $0.identifier(.bcp47) }.contains(resolved.identifier(.bcp47))
    }

    public func startSession(chunks: AsyncStream<[Float]>) async -> AsyncStream<LiveUpdate> {
        await endSession()   // one session at a time

        let (updates, updateContinuation) = AsyncStream.makeStream(of: LiveUpdate.self)
        let transcriber = SpeechTranscriber(locale: await resolvedLocale(),
                                            preset: .progressiveTranscription)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]),
              let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: CaptureKit.AudioData.sampleRate,
                                              channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: floatFormat, to: analyzerFormat)
        else {
            updateContinuation.finish()
            return updates
        }

        let (inputSequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.inputBuilder = builder

        // Results consumer MUST be running before audio is fed (verified:
        // results delivered while nobody iterates are silently dropped).
        let resultsTask = Task {
            var finalized = ""
            var volatile = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        finalized = finalized.isEmpty ? text : finalized + " " + text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    updateContinuation.yield(LiveUpdate(finalizedText: finalized,
                                                        volatileText: volatile))
                }
            } catch {}   // analysis teardown ends the sequence; nothing to surface
        }

        // Analysis runs CONCURRENTLY with feeding — analyzeSequence consumes
        // the input stream as buffers arrive and returns when it finishes.
        let analysisTask = Task {
            _ = try? await analyzer.analyzeSequence(inputSequence)
            await analyzer.cancelAndFinishNow()   // ends transcriber.results
        }

        // Feed chunks → Int16 analyzer buffers until the capture stream ends.
        pumpTask = Task { [weak self] in
            for await samples in chunks {
                guard !Task.isCancelled else { break }
                guard let buffer = Self.makeInt16Buffer(samples, floatFormat: floatFormat,
                                                        converter: converter,
                                                        analyzerFormat: analyzerFormat)
                else { continue }
                builder.yield(AnalyzerInput(buffer: buffer))
            }
            builder.finish()
            _ = await analysisTask.result
            _ = await resultsTask.result
            updateContinuation.finish()
            await self?.clearSession()
        }

        return updates
    }

    public func endSession() async {
        inputBuilder?.finish()
        inputBuilder = nil
        pumpTask = nil   // pump drains and completes on its own
    }

    private func clearSession() {
        analyzer = nil
        inputBuilder = nil
        pumpTask = nil
    }

    private static func makeInt16Buffer(_ samples: [Float],
                                        floatFormat: AVAudioFormat,
                                        converter: AVAudioConverter,
                                        analyzerFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                                 frameCapacity: AVAudioFrameCount(samples.count)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat,
                                               frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        floatBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            floatBuffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        // Same sample rate (16 kHz float -> 16 kHz Int16): the simple
        // non-block convert API applies and keeps no converter state.
        do {
            try converter.convert(to: outBuffer, from: floatBuffer)
            return outBuffer
        } catch {
            return nil
        }
    }
}
