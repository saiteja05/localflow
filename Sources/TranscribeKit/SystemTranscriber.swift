import AVFoundation
import Foundation
import Speech
import CaptureKit

/// Apple SpeechAnalyzer (macOS 26): the zero-download transcriber used while
/// Parakeet downloads or as fallback. Weaker on jargon; no auto language ID.
public actor SystemTranscriber: Transcriber {
    private let locale: Locale

    public init(locale: Locale = Locale(identifier: "en_US")) {
        self.locale = locale
    }

    public func isReady() async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    /// Reserve the locale and download the system asset if needed (system-managed, shared).
    public func prepare() async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
            throw TranscriptionError.modelUnavailable
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) {
            try await AssetInventory.reserve(locale: locale)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()   // fast no-op when already installed
        }
    }

    public func transcribe(_ audio: CaptureKit.AudioData) async throws -> Transcript {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // CRASH HAZARD (verified): the analyzer accepts ONLY 16/8 kHz mono Int16.
        // Feeding Float32 traps the process. Always convert.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]) else {
            throw TranscriptionError.audioFormatUnsupported
        }
        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: CaptureKit.AudioData.sampleRate,
                                        channels: 1, interleaved: false)!
        guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                                 frameCapacity: AVAudioFrameCount(audio.samples.count))
        else { throw TranscriptionError.audioFormatUnsupported }
        floatBuffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { src in
            floatBuffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        let int16Buffer = try Self.convert(floatBuffer, to: analyzerFormat)

        // Consume results BEFORE feeding input, or they are silently lost (verified).
        async let transcriptFuture: AttributedString = transcriber.results
            .reduce(AttributedString()) { partial, result in partial + result.text }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        inputBuilder.yield(AnalyzerInput(buffer: int16Buffer))
        inputBuilder.finish()

        if let lastSampleTime = try await analyzer.analyzeSequence(inputSequence) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = String((try await transcriptFuture).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, languageHint: locale.identifier(.bcp47))
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TranscriptionError.audioFormatUnsupported
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.audioFormatUnsupported
        }
        nonisolated(unsafe) var supplied = false
        var err: NSError?
        let status = converter.convert(to: output, error: &err) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw TranscriptionError.audioFormatUnsupported }
        return output
    }
}
