import AppKit

public enum FrontmostApp {
    public static func bundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
