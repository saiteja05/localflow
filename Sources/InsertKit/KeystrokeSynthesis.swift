import CoreGraphics

/// Raw CGEvent keystroke synthesis: layout-independent unicode typing and
/// hardware-equivalent backspace. Last-resort insertion path, and the only
/// path compatible with incremental per-character live-typing.
public enum KeystrokeSynthesis {
    public static func typeUnicode(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for chunk in UnicodeChunker.chunks(of: text) {
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(8))   // pacing: fast posting drops chars
        }
    }

    public static func backspace(count: Int) async {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),  // kVK_Delete
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            else { continue }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
