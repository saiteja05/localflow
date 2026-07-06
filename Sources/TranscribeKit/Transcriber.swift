import Foundation
import CaptureKit

public struct Transcript: Sendable, Equatable {
    public var text: String
    public var languageHint: String?   // BCP-47; Parakeet does not detect language (input hint only)
    public init(text: String, languageHint: String?) {
        self.text = text
        self.languageHint = languageHint
    }
}

public protocol Transcriber: Sendable {
    func isReady() async -> Bool
    func transcribe(_ audio: CaptureKit.AudioData) async throws -> Transcript
}

public enum TranscriptionError: Error {
    case modelUnavailable
    case audioFormatUnsupported
    case engineFailure(String)
}
