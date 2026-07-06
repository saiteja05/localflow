import Testing
@testable import HotkeyKit

struct KeyEventInterpreterTests {
    @Test func fnPressAndRelease() {
        var i = KeyEventInterpreter(choice: .fnKey)
        let down = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        #expect(down.event == .keyDown && down.swallow == true)
        let up = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: 0))
        #expect(up.event == .keyUp && up.swallow == true)
    }
    @Test func arrowKeySettingFnFlagIsIgnored() {
        var i = KeyEventInterpreter(choice: .fnKey)
        let out = i.interpret(.flagsChanged(keyCode: 123, flags: KeyFlags.secondaryFn)) // left arrow
        #expect(out.event == nil && out.swallow == false)
    }
    @Test func comboCancelsHoldAndSuppressesKeyUp() {
        var i = KeyEventInterpreter(choice: .fnKey)
        _ = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        let cancel = i.interpret(.keyDown(keyCode: 123, flags: KeyFlags.secondaryFn)) // Fn+left
        #expect(cancel.event == .comboCancelled && cancel.swallow == false)
        let release = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: 0))
        #expect(release.event == nil)   // keyUp suppressed after cancellation
    }
    @Test func rightCommandPressReleaseNotSwallowed() {
        var i = KeyEventInterpreter(choice: .rightCommand)
        let down = i.interpret(.flagsChanged(keyCode: KeyCodes.rightCommand, flags: KeyFlags.command))
        #expect(down.event == .keyDown && down.swallow == false)
        let up = i.interpret(.flagsChanged(keyCode: KeyCodes.rightCommand, flags: 0))
        #expect(up.event == .keyUp && up.swallow == false)
    }
    @Test func customComboPressRelease() {
        var i = KeyEventInterpreter(choice: .custom(keyCode: 49, modifierRawValue: KeyFlags.command)) // ⌘Space
        let down = i.interpret(.keyDown(keyCode: 49, flags: KeyFlags.command))
        #expect(down.event == .keyDown && down.swallow == true)
        // Release matches on keyCode even if the modifier lifted first:
        let up = i.interpret(.keyUp(keyCode: 49, flags: 0))
        #expect(up.event == .keyUp && up.swallow == true)
    }
    @Test func customComboWithoutModifierDoesNotTrigger() {
        var i = KeyEventInterpreter(choice: .custom(keyCode: 49, modifierRawValue: KeyFlags.command))
        let out = i.interpret(.keyDown(keyCode: 49, flags: 0))
        #expect(out.event == nil && out.swallow == false)
    }
    @Test func escapeWhileIdleEmitsEscapePressed() {
        var i = KeyEventInterpreter(choice: .fnKey)
        let out = i.interpret(.keyDown(keyCode: KeyCodes.escape, flags: 0))
        #expect(out.event == .escapePressed && out.swallow == false)
    }
    @Test func escapeWhileHoldingIsComboCancel() {
        var i = KeyEventInterpreter(choice: .fnKey)
        _ = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        let out = i.interpret(.keyDown(keyCode: KeyCodes.escape, flags: KeyFlags.secondaryFn))
        #expect(out.event == .comboCancelled)
    }
    @Test func repeatedFlagsChangedWhileHeldEmitsNothing() {
        var i = KeyEventInterpreter(choice: .fnKey)
        _ = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        let dup = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        #expect(dup.event == nil)
    }
}
