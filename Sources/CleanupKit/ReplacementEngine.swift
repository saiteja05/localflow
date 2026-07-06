import Foundation

/// Deterministic user-defined substitutions ("spoken form" -> "written form").
/// Applied AFTER the LLM pass — the LLM must never be trusted with these.
public enum ReplacementEngine {
    public static func apply(_ replacements: [Replacement], to text: String) -> String {
        var s = text
        // Longest spoken form first so "my sequel" beats "sequel".
        for r in replacements.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            guard !r.spoken.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: r.spoken)
            // Word-ish boundaries that tolerate non-word chars in the term itself (c++).
            let pattern = #"(?i)(?<![\w'])"# + escaped + #"(?![\w'])"#
            s = s.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: r.written),
                options: .regularExpression)
        }
        return s
    }
}
