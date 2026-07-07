import AppKit
import ApplicationServices
import Carbon.HIToolbox

public enum Permissions {
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt directing the user to System Settings.
    public static func requestAccessibility() {
        // The key is "AXTrustedCheckOptionPrompt" as per Apple's header
        let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// True while any process holds Secure Event Input (password fields,
    /// terminals with Secure Keyboard Entry). Event taps go deaf during it (spec §5).
    public static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Name of the app holding Secure Event Input, when determinable (spec §5:
    /// tell the user WHICH app). Returns nil when secure input is off.
    public static func secureInputAppName() -> String? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = dict["kCGSSessionSecureInputPID"] as? Int32 else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }
}
