import AppKit
import ApplicationServices
import CoreGraphics

public final class TextInserter: TextInserting, @unchecked Sendable {
    private let table: StrategyTable
    private let clipboardRestoreDelay: TimeInterval

    public init(table: StrategyTable = StrategyTable(), clipboardRestoreDelay: TimeInterval = 0.3) {
        self.table = table
        self.clipboardRestoreDelay = clipboardRestoreDelay
    }

    public func insert(_ text: String, bundleID: String?) async -> InsertionOutcome {
        switch table.strategy(for: bundleID) {
        case .axSelectedText:
            if await insertViaAX(text) { return .inserted(.axSelectedText) }
            // AX failed (focus element refused) — fall through to the universal path.
            return await pasteSwap(text)
        case .pasteSwap:
            return await pasteSwap(text)
        case .typedUnicode:
            await KeystrokeSynthesis.typeUnicode(text)
            return .inserted(.typedUnicode)
        }
    }

    // MARK: AX — clean insertion at the caret, no clipboard, native apps only.
    @MainActor
    private func insertViaAX(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return false }
        let ax = unsafeDowncast(element as AnyObject, to: AXUIElement.self)
        // Setting kAXSelectedTextAttribute replaces the selection (or inserts at the caret).
        return AXUIElementSetAttributeValue(ax,
                kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    // MARK: Paste swap — snapshot clipboard, transient paste, ⌘V, restore.
    private func pasteSwap(_ text: String) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers (Raycast, Maccy…) honor this and skip the entry.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        guard postCmdV() else {
            // Could not synthesize the keystroke: leave transcript on the clipboard (spec §5).
            return .failedTextOnClipboard
        }
        try? await Task.sleep(for: .seconds(clipboardRestoreDelay))
        snapshot.restore(to: pasteboard)
        return .inserted(.pasteSwap)
    }

    private func postCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),  // kVK_ANSI_V
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
