import Foundation
import FluidAudio
import CaptureKit

/// Primary STT: NVIDIA Parakeet TDT 0.6b-v3 on the Neural Engine via FluidAudio.
/// ~0.2-0.5s for typical utterances; 25 European languages; stays resident.
public actor ParakeetTranscriber: Transcriber {
    public enum State: Sendable, Equatable {
        case notPrepared, downloading(Double), ready, failed(String)
    }
    public private(set) var state: State = .notPrepared
    private var manager: AsrManager?
    private var vad: VadManager?
    private var language: Language?

    public init() {}

    public static var modelIsDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    /// BCP-47-ish code from settings ("en", "de", …); nil = auto-detect.
    public func setLanguage(_ bcp47: String?) {
        language = bcp47.flatMap { Language(rawValue: String($0.prefix(2))) }
    }

    public func isReady() async -> Bool { state == .ready }

    /// Downloads (~600MB, once) and loads the models. Progress: fraction + phase label.
    public func prepare(progress: (@Sendable (Double, String) -> Void)?) async throws {
        guard state != .ready else { return }
        state = .downloading(0)
        do {
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { p in
                    let label: String
                    switch p.phase {
                    case .listing: label = "Preparing download…"
                    case .downloading(let done, let total): label = "Downloading model \(done)/\(total)…"
                    case .compiling(let name): label = "Compiling \(name)…"
                    }
                    progress?(p.fractionCompleted, label)
                })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            // VAD is best-effort: silence trimming improves quality but must never block.
            self.vad = try? await VadManager()
            state = .ready
        } catch {
            state = .failed(String(describing: error))
            throw TranscriptionError.engineFailure(String(describing: error))
        }
    }

    public func transcribe(_ audio: CaptureKit.AudioData) async throws -> Transcript {
        guard let manager, state == .ready else { throw TranscriptionError.modelUnavailable }
        // FluidAudio throws ASRError.invalidAudioData under 4800 samples (0.3s).
        guard audio.samples.count >= 4800 else {
            return Transcript(text: "", languageHint: language?.rawValue)
        }
        var samples = audio.samples
        if let vad {
            // Trim non-speech; keep raw audio if VAD errors or finds nothing
            // (better to transcribe silence than to drop real speech).
            if let segments = try? await vad.segmentSpeechAudio(samples), !segments.isEmpty {
                samples = segments.flatMap { $0 }
            }
        }
        guard samples.count >= 4800 else {
            return Transcript(text: "", languageHint: language?.rawValue)
        }
        var decoderState = try TdtDecoderState()   // fresh per utterance (no cross-talk)
        let result = try await manager.transcribe(samples, decoderState: &decoderState,
                                                  language: language)
        return Transcript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                          languageHint: language?.rawValue)
    }
}
