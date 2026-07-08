import AppKit
import Foundation

/// Resolves a bundle ID to a human-readable app name for currently-running
/// apps and, unlike a running-apps-only lookup, for installed-but-quit apps
/// too (needed by history entries from apps that may have exited already).
enum AppDisplayName {
    static func resolve(_ bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}
