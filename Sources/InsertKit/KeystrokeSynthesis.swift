import CoreGraphics
import Foundation

// DEBUG-LIVETYPE
private func liveTypeDebugLog(_ message: String) {
    let line = "\(Date()): \(message)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/localflow-livetype-debug.log"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Raw CGEvent keystroke synthesis: layout-independent unicode typing and
/// hardware-equivalent backspace. Last-resort insertion path, and the only
/// path compatible with incremental per-character live-typing.
public enum KeystrokeSynthesis {
    public static func typeUnicode(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { liveTypeDebugLog("KeystrokeSynthesis.typeUnicode: CGEventSource creation FAILED"); return }   // DEBUG-LIVETYPE
        liveTypeDebugLog("KeystrokeSynthesis.typeUnicode() called with text=\(text.prefix(50))")   // DEBUG-LIVETYPE
        for chunk in UnicodeChunker.chunks(of: text) {
            liveTypeDebugLog("KeystrokeSynthesis.typeUnicode: posting chunk=\(chunk)")   // DEBUG-LIVETYPE
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { liveTypeDebugLog("KeystrokeSynthesis.typeUnicode: CGEvent creation FAILED for chunk"); continue }   // DEBUG-LIVETYPE
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(8))   // pacing: fast posting drops chars
        }
    }

    public static func backspace(count: Int) async {
        liveTypeDebugLog("KeystrokeSynthesis.backspace() called with count=\(count)")   // DEBUG-LIVETYPE
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { liveTypeDebugLog("KeystrokeSynthesis.backspace: CGEventSource creation FAILED"); return }   // DEBUG-LIVETYPE
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),  // kVK_Delete
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            else { liveTypeDebugLog("KeystrokeSynthesis.backspace: CGEvent creation FAILED for chunk"); continue }   // DEBUG-LIVETYPE
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
