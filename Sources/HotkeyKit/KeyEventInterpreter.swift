import Foundation

/// Pure translator from low-level key events to hotkey semantics.
/// Owns NO timing logic — short-press and double-tap live in FlowCore.GestureMachine.
public struct KeyEventInterpreter: Sendable {
    public enum CGInput: Equatable, Sendable {
        case flagsChanged(keyCode: UInt16, flags: UInt64)
        case keyDown(keyCode: UInt16, flags: UInt64)
        case keyUp(keyCode: UInt16, flags: UInt64)
    }
    public typealias Output = (event: HotkeyRawEvent?, swallow: Bool)

    private let choice: HotkeyChoice
    private var holding = false
    private var cancelled = false

    public init(choice: HotkeyChoice) {
        self.choice = choice
    }

    public mutating func interpret(_ input: CGInput) -> Output {
        switch (choice, input) {
        // --- Fn/Globe: flagsChanged keyCode 63; bit set = press, clear = release.
        case (.fnKey, .flagsChanged(KeyCodes.fn, let flags)):
            return handleModifierEdge(bitSet: flags & KeyFlags.secondaryFn != 0, swallow: true)
        // --- Right ⌘: flagsChanged keyCode 54. Never swallow (⌘-combos must keep working).
        case (.rightCommand, .flagsChanged(KeyCodes.rightCommand, let flags)):
            return handleModifierEdge(bitSet: flags & KeyFlags.command != 0, swallow: false)
        // --- Custom combo: plain keyDown/keyUp with required modifiers.
        case (.custom(let kc, let mods), .keyDown(let inputKc, let flags)) where inputKc == kc && flags & mods == mods && !holding:
            holding = true; cancelled = false
            return (.keyDown, true)
        case (.custom(let kc, _), .keyUp(let inputKc, _)) where inputKc == kc && holding:
            holding = false
            return cancelled ? (nil, true) : (.keyUp, true)
        default:
            break
        }
        // Any other keyDown: combo-cancel if mid-hold; Esc signal if idle.
        if case .keyDown(let kc, _) = input {
            if holding, !cancelled {
                cancelled = true
                return (.comboCancelled, false)
            }
            if !holding, kc == KeyCodes.escape {
                return (.escapePressed, false)
            }
        }
        return (nil, false)
    }

    private mutating func handleModifierEdge(bitSet: Bool, swallow: Bool) -> Output {
        if bitSet {
            guard !holding else { return (nil, swallow) }   // repeat
            holding = true; cancelled = false
            return (.keyDown, swallow)
        } else {
            guard holding else { return (nil, false) }
            holding = false
            return cancelled ? (nil, swallow) : (.keyUp, swallow)
        }
    }
}
