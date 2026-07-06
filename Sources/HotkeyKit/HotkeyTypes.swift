import Foundation

public enum HotkeyChoice: Codable, Equatable, Sendable {
    case fnKey
    case rightCommand
    case custom(keyCode: UInt16, modifierRawValue: UInt64)
}

public enum HotkeyRawEvent: Sendable, Equatable {
    case keyDown          // hotkey hold began
    case keyUp            // hotkey hold ended
    case comboCancelled   // another key pressed mid-hold (user meant Fn+arrow etc.)
    case escapePressed    // Esc pressed while hotkey not held
    case secureInputChanged(Bool)
}

public protocol HotkeySource: Sendable {
    var events: AsyncStream<HotkeyRawEvent> { get }
    func start() throws
}

public enum KeyCodes {
    public static let fn: UInt16 = 63            // kVK_Function
    public static let rightCommand: UInt16 = 54  // kVK_RightCommand
    public static let escape: UInt16 = 53        // kVK_Escape
}

public enum KeyFlags {
    public static let secondaryFn: UInt64 = 0x0080_0000  // CGEventFlags.maskSecondaryFn
    public static let command: UInt64 = 0x0010_0000      // CGEventFlags.maskCommand
    public static let option: UInt64 = 0x0008_0000       // CGEventFlags.maskAlternate
    public static let control: UInt64 = 0x0004_0000      // CGEventFlags.maskControl
    public static let shift: UInt64 = 0x0002_0000        // CGEventFlags.maskShift
}
