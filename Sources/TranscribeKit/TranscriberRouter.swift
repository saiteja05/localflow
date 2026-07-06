import CaptureKit

/// Prefers the primary (Parakeet) when ready; falls back to the system
/// transcriber so dictation works from first launch (spec §2, §5).
public struct TranscriberRouter: Transcriber {
    private let primary: any Transcriber
    private let fallback: any Transcriber

    public init(primary: any Transcriber, fallback: any Transcriber) {
        self.primary = primary
        self.fallback = fallback
    }
    public func isReady() async -> Bool {
        if await primary.isReady() { return true }
        return await fallback.isReady()
    }
    public func transcribe(_ audio: CaptureKit.AudioData) async throws -> Transcript {
        if await primary.isReady() {
            return try await primary.transcribe(audio)
        }
        return try await fallback.transcribe(audio)
    }
}
