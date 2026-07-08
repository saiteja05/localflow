import Foundation

/// Detects edit-mode outputs that violate `PromptBuilder.editInstructions()`'s
/// "no preamble, no quotes, no commentary" contract. Small local models
/// occasionally narrate instead of editing (e.g. "Sure, here is a softer
/// version of the transcript: ..."), fabricating unrelated content instead of
/// operating on the real selection. `CleanupPipeline.transform` rejects
/// non-compliant output and falls through to the next provider.
enum EditResponseGuard {
    private static let preamblePrefixes = [
        "sure,", "sure!", "sure -", "sure —",
        "certainly,", "certainly!",
        "of course,", "of course!",
        "absolutely,", "absolutely!",
        "here is", "here's",
        "okay, here", "ok, here",
        "no problem,",
    ]

    static func isCompliant(_ text: String) -> Bool {
        let lower = text.lowercased()
        return !preamblePrefixes.contains { lower.hasPrefix($0) }
    }
}
