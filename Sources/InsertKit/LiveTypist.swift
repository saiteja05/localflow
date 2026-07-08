/// Types the live/volatile transcript into the focused app as it streams in,
/// diffing each update against what's already been typed so only the delta
/// is sent. `clearTyped()` backspaces out everything currently tracked.
public protocol LiveTyping: Sendable {
    func begin() async
    func update(_ text: String) async
    func clearTyped() async
}

public actor LiveTypist: LiveTyping {
    private var typed: String = ""

    public init() {}

    public func begin() async {
        typed = ""
    }

    public func update(_ text: String) async {
        let diff = LiveTypeDiff.compute(from: typed, to: text)
        await KeystrokeSynthesis.backspace(count: diff.backspaces)
        await KeystrokeSynthesis.typeUnicode(diff.suffix)
        typed = text
    }

    public func clearTyped() async {
        await KeystrokeSynthesis.backspace(count: typed.count)
        typed = ""
    }
}
