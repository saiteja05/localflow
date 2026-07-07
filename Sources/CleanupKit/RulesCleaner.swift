import Foundation

/// Deterministic, instant transcript cleanup. Conservative by design:
/// only removes unambiguous fillers; never adds terminal punctuation
/// (users dictate fragments into search boxes).
public enum RulesCleaner {
    // Standalone filler words (word-boundary, case-insensitive).
    private static let fillers = ["um", "uh", "uhm", "umm", "erm", "er", "ah", "hmm"]

    public static func clean(_ text: String) -> String {
        var s = text

        // 1. Strip standalone fillers, consuming one adjacent comma if present:
        //    "um, so" -> "so";  "so, um, the" -> "so, the";  "I um think" -> "I think"
        let fillerAlternation = fillers.joined(separator: "|")
        s = s.replacingOccurrences(
            of: #"(?i)(?<![\w'])(?:\#(fillerAlternation))(?![\w'])[,]?\s*"#,
            with: "", options: .regularExpression)

        // 2. "you know" only at clause boundaries (start-or-after-comma AND before-comma).
        s = s.replacingOccurrences(
            of: #"(?i)(^|,)\s*you know\s*,\s*"#,
            with: "$1 ", options: .regularExpression)

        // 3. Collapse immediate word repetitions ("the the" -> "the"), keep the first token.
        while let range = s.range(
            of: #"(?i)(?<![\w'])([\w']+)(\s+\1)(?![\w'])"#, options: .regularExpression) {
            let match = String(s[range])
            let first = match.split(separator: " ", maxSplits: 1)[0]
            s = s.replacingCharacters(in: range, with: String(first))
        }

        // 4. Whitespace + punctuation spacing: collapse runs; no space before , . ! ? ; :
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        // Leftover doubled commas from removals: ", ," -> ","
        s = s.replacingOccurrences(of: #",\s*,"#, with: ",", options: .regularExpression)
        // Leading orphan punctuation after removals: "^, so" -> "so"
        s = s.replacingOccurrences(of: #"^[\s,.!?;:]+"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Capitalize first letter (leave the rest untouched).
        if let first = s.first, first.isLowercase {
            s = first.uppercased() + s.dropFirst()
        }
        return s
    }
}
