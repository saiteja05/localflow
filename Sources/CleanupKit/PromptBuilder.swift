import Foundation

/// Single prompt contract shared by every LLM provider (spec §3).
/// Keep instructions short: they count against Apple FM's 4096-token window.
public enum PromptBuilder {
    public static func instructions(level: CleanupLevel, vocabulary: [String],
                                    tone: Tone = .neutral) -> String {
        var lines = [
            "You clean up dictated text.",
            "Fix punctuation and capitalization. Remove filler words and false starts.",
            "Apply self-corrections: if the speaker says \"no wait\" or \"I mean\", keep only the corrected version.",
            "Preserve wording and meaning otherwise. Keep the same language as the input.",
        ]
        if level == .heavy {
            lines.append("Also fix grammar, split run-on sentences, and format spoken enumerations (\"first... second...\") as lists.")
        }
        if !vocabulary.isEmpty {
            lines.append("Vocabulary that may appear (use exact spelling): \(vocabulary.joined(separator: ", ")).")
        }
        switch tone {
        case .neutral: break
        case .casual:  lines.append("Match a casual, conversational tone.")
        case .formal:  lines.append("Use a formal, professional tone.")
        }
        lines.append("Output only the cleaned text — no preamble, no quotes, no commentary.")
        return lines.joined(separator: " ")
    }

    public static func userPrompt(for transcript: String) -> String {
        "Transcript:\n" + transcript
    }

    // MARK: edit mode (spoken instruction applied to selected text)

    public static func editInstructions() -> String {
        "You edit text according to the user's spoken instruction. "
        + "Apply the instruction to the text faithfully. "
        + "Change nothing beyond what the instruction requires. "
        + "Keep the same language as the text unless told otherwise. "
        + "Output only the edited text — no preamble, no quotes, no commentary."
    }

    public static func editUserPrompt(selection: String, instruction: String) -> String {
        "Instruction:\n" + instruction + "\n\nText:\n" + selection
    }
}
