import Foundation

/// Types the live/volatile transcript into the focused app as it streams in,
/// diffing each update against what's already been typed so only the delta
/// is sent. `clearTyped()` backspaces out everything currently tracked.
public protocol LiveTyping: Sendable {
    func begin() async
    func update(_ text: String) async
    func clearTyped() async
}

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

public actor LiveTypist: LiveTyping {
    private var typed: String = ""

    public init() {}

    public func begin() async {
        liveTypeDebugLog("LiveTypist.begin() called")   // DEBUG-LIVETYPE
        typed = ""
    }

    public func update(_ text: String) async {
        liveTypeDebugLog("LiveTypist.update() called with text=\(text.prefix(50))")   // DEBUG-LIVETYPE
        let diff = LiveTypeDiff.compute(from: typed, to: text)
        liveTypeDebugLog("LiveTypist.update() diff: backspaces=\(diff.backspaces) suffix=\(diff.suffix.prefix(50))")   // DEBUG-LIVETYPE
        await KeystrokeSynthesis.backspace(count: diff.backspaces)
        await KeystrokeSynthesis.typeUnicode(diff.suffix)
        typed = text
    }

    public func clearTyped() async {
        liveTypeDebugLog("LiveTypist.clearTyped() called, typed.count=\(typed.count)")   // DEBUG-LIVETYPE
        await KeystrokeSynthesis.backspace(count: typed.count)
        typed = ""
    }
}
