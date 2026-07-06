/// Per-app insertion strategy. Curated list is deliberately small: AX only where
/// verified reliable; EVERYTHING unknown gets pasteSwap (spec §3).
public struct StrategyTable: Sendable {
    public static let curatedDefaults: [String: InsertionStrategy] = [
        "com.apple.TextEdit": .axSelectedText,
        "com.apple.Notes": .axSelectedText,
        "com.apple.Stickies": .axSelectedText,
    ]
    private let overrides: [String: InsertionStrategy]

    public init(overrides: [String: InsertionStrategy] = [:]) {
        self.overrides = overrides
    }
    public func strategy(for bundleID: String?) -> InsertionStrategy {
        guard let id = bundleID else { return .pasteSwap }
        return overrides[id] ?? Self.curatedDefaults[id] ?? .pasteSwap
    }
}
