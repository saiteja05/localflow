import Foundation

/// Deterministic mid-dictation voice commands, spoken alongside the content
/// they act on. Two vocabularies run at different pipeline stages:
/// `apply` (discard) runs on the raw transcript before cleanup; `applyFormatting`
/// (newlines) must run after cleanup, since RulesCleaner collapses all
/// whitespace and would otherwise flatten literal newlines back to a space.
public enum VoiceCommandProcessor {
    // 1. Discard everything since the last "scratch/strike/undo/delete that".
    private static let discardPattern = #"(?i)\b(?:scratch|strike|undo|delete)\s+that\b"#

    public static func apply(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: discardPattern) else { return raw }
        let full = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: full.length))
        guard let last = matches.last else { return raw }
        let tail = full.substring(from: last.range.location + last.range.length)
        return tail.replacingOccurrences(of: #"^[\s,.!?;:]+"#, with: "", options: .regularExpression)
    }

    // 2. Convert "new paragraph" / "new line" into literal newlines.
    public static func applyFormatting(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(
            of: #"(?i)\s*\bnew paragraph\b\s*"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(?i)\s*\bnew line\b\s*"#, with: "\n", options: .regularExpression)
        return s
    }
}
