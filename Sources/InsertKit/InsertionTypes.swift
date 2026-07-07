public enum InsertionStrategy: String, Codable, Sendable {
    case axSelectedText   // Accessibility API — native Cocoa apps only
    case pasteSwap        // clipboard swap + synthetic ⌘V — universal default
    case typedUnicode     // chunked CGEventKeyboardSetUnicodeString — last resort
}

public enum InsertionOutcome: Equatable, Sendable {
    case inserted(InsertionStrategy)
    case failedTextOnClipboard   // couldn't insert; transcript left on the clipboard
}

public protocol TextInserting: Sendable {
    func insert(_ text: String, bundleID: String?) async -> InsertionOutcome
}
