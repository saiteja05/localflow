/// CGEventKeyboardSetUnicodeString silently truncates around 20 UTF-16 units
/// per event — chunk at 18, never splitting a grapheme cluster.
public enum UnicodeChunker {
    public static func chunks(of text: String, maxUTF16PerChunk: Int = 18) -> [String] {
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for ch in text {
            let units = ch.utf16.count
            if currentUnits + units > maxUTF16PerChunk, !current.isEmpty {
                result.append(current)
                current = ""; currentUnits = 0
            }
            current.append(ch)
            currentUnits += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
