import Testing
@testable import InsertKit

struct StrategyTableTests {
    @Test func unknownAppDefaultsToPasteSwap() {
        #expect(StrategyTable().strategy(for: "com.example.unknown") == .pasteSwap)
    }
    @Test func nilBundleIDDefaultsToPasteSwap() {
        #expect(StrategyTable().strategy(for: nil) == .pasteSwap)
    }
    @Test func curatedNativeAppsUseAX() {
        let t = StrategyTable()
        #expect(t.strategy(for: "com.apple.TextEdit") == .axSelectedText)
        #expect(t.strategy(for: "com.apple.Notes") == .axSelectedText)
    }
    @Test func overridesBeatCuratedDefaults() {
        let t = StrategyTable(overrides: ["com.apple.TextEdit": .typedUnicode])
        #expect(t.strategy(for: "com.apple.TextEdit") == .typedUnicode)
    }
}
