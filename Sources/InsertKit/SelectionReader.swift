import AppKit
import ApplicationServices

/// Reads the current selection from the frontmost app for edit mode.
/// AX first (clean, no clipboard); synthetic ⌘C with full clipboard
/// restore as the universal fallback (browsers/Electron).
public enum SelectionReader {
    public static func currentSelection() async -> String? {
        if let text = await MainActor.run(body: { axSelection() }), !text.isEmpty {
            return text
        }
        return await copySelection()
    }

    @MainActor
    private static func axSelection() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        let ax = unsafeDowncast(element as AnyObject, to: AXUIElement.self)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax,
                kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String
        else { return nil }
        return text
    }

    /// ⌘C into a snapshotted clipboard; restore afterwards. A changeCount
    /// that doesn't move means nothing was selected.
    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let before = pasteboard.changeCount
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),  // kVK_ANSI_C
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(150))
        let text = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
        snapshot.restore(to: pasteboard)
        return text?.isEmpty == false ? text : nil
    }
}
