import Foundation
import Testing
@testable import Persistence
import CleanupKit
import HotkeyKit

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "localflow-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct SettingsStoreTests {
    @Test func freshStoreHasDefaults() {
        let store = SettingsStore(directory: tempDir())
        #expect(store.settings == AppSettings())
        #expect(store.settings.cleanupLevel == .standard)
        #expect(store.settings.hotkey == .fnKey)
        #expect(store.settings.historyRetention == 100)
    }
    @Test func updatePersistsAcrossReload() {
        let dir = tempDir()
        let store = SettingsStore(directory: dir)
        var s = store.settings
        s.cleanupLevel = .heavy
        s.hotkey = .rightCommand
        store.update(s)
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.cleanupLevel == .heavy)
        #expect(reloaded.settings.hotkey == .rightCommand)
    }
    @Test func corruptFileFallsBackToDefaults() throws {
        let dir = tempDir()
        try Data("not json".utf8).write(to: dir.appending(path: "settings.json"))
        #expect(SettingsStore(directory: dir).settings == AppSettings())
    }
    @Test func decodingToleratesMissingKeys() throws {
        let dir = tempDir()
        try Data(#"{"cleanupLevel":"light"}"#.utf8).write(to: dir.appending(path: "settings.json"))
        let store = SettingsStore(directory: dir)
        #expect(store.settings.cleanupLevel == .light)     // provided key honored
        #expect(store.settings.historyRetention == 100)    // missing keys -> defaults
    }
}
