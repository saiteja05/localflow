import Foundation

// Hashable (not just Equatable): SwiftUI's Settings window uses HotkeyChoice as
// a Picker selection/tag value, which requires Hashable. All associated values
// (UInt16, UInt64) are themselves Hashable, so this is a compiler-synthesized
// no-op addition — no behavior change for existing Equatable-only callers.
public enum HotkeyChoice: Codable, Hashable, Sendable {
    case fnKey
    case rightCommand
    case rightOption
    case custom(keyCode: UInt16, modifierRawValue: UInt64)
    case modifierChord(anchorKeyCode: UInt16, qualifierFlags: UInt64)
}

public enum HotkeyRawEvent: Sendable, Equatable {
    case keyDown            // dictation hotkey hold began
    case keyUp              // dictation hotkey hold ended
    case comboCancelled     // another key pressed mid-hold (user meant Fn+arrow etc.)
    case escapePressed      // Esc pressed while hotkey not held
    case editKeyDown        // edit hotkey (Right ⌥) hold began
    case editKeyUp          // edit hotkey hold ended
    case editCancelled      // combo pressed mid-edit-hold
    case secureInputChanged(Bool)
}

public protocol HotkeySource: Sendable {
    var events: AsyncStream<HotkeyRawEvent> { get }
    func start() throws
}

public enum KeyCodes {
    public static let fn: UInt16 = 63            // kVK_Function
    public static let rightCommand: UInt16 = 54  // kVK_RightCommand
    public static let rightOption: UInt16 = 61   // kVK_RightOption (edit mode)
    public static let escape: UInt16 = 53        // kVK_Escape
}

public enum KeyFlags {
    public static let secondaryFn: UInt64 = 0x0080_0000  // CGEventFlags.maskSecondaryFn
    public static let command: UInt64 = 0x0010_0000      // CGEventFlags.maskCommand
    public static let option: UInt64 = 0x0008_0000       // CGEventFlags.maskAlternate
    public static let control: UInt64 = 0x0004_0000      // CGEventFlags.maskControl
    public static let shift: UInt64 = 0x0002_0000        // CGEventFlags.maskShift

    /// Union of every modifier bit KeyEventInterpreter reasons about. A chord's
    /// exact-match check compares against this mask so CGEventFlags noise bits
    /// (caps lock, numeric pad, device-dependent bits) never affect the result.
    public static let allTracked: UInt64 = secondaryFn | command | option | control | shift
}

/// Tag applied (via `CGEventField.eventSourceUserData`) to CGEvents this app
/// synthesizes and posts itself — e.g. SelectionReader's ⌘C fallback — so
/// EventTapHotkeySource can recognize and ignore them instead of misreading
/// its own synthetic keystroke as a real key press that should cancel an
/// in-progress hotkey hold.
public enum SyntheticEventTag {
    public static let userData: Int64 = 0x4C_46_45_44_49_54  // "LFEDIT", arbitrary non-zero sentinel
}

/// Maps a physical modifier key's keycode to the CGEventFlags bit it
/// contributes. Lets a modifier-chord hotkey recognize its qualifier key
/// regardless of which physical key (left/right) the user presses.
public enum ModifierKey {
    public static func flag(forKeyCode keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 63: return KeyFlags.secondaryFn        // kVK_Function
        case 54, 55: return KeyFlags.command        // kVK_RightCommand, kVK_Command
        case 58, 61: return KeyFlags.option          // kVK_Option, kVK_RightOption
        case 59, 62: return KeyFlags.control         // kVK_Control, kVK_RightControl
        case 56, 60: return KeyFlags.shift           // kVK_Shift, kVK_RightShift
        default: return nil
        }
    }
}
