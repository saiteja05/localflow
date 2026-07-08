import Foundation

/// Sanitizes and validates LLM output against the "no preamble, no quotes,
/// no commentary" contract shared by both prompt paths (`PromptBuilder.
/// instructions()` for dictation cleanup, `editInstructions()` for edit
/// mode). Small local models occasionally narrate instead of complying
/// (e.g. "Sure, here is a softer version of the transcript: ..." or
/// wrapping the whole reply in quotes) — `CleanupPipeline` runs every
/// provider response through this before accepting it.
enum ResponseGuard {
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

    private static let quotePairs: [(Character, Character)] = [
        ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"),
    ]

    /// Strips one matching pair of wrapping quote marks, if the entire
    /// response is wrapped in them despite the "no quotes" instruction.
    static func stripWrappingQuotes(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              quotePairs.contains(where: { $0 == first && $1 == last })
        else { return text }
        return String(text.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
