import AppKit
import Testing
@testable import InsertKit

struct PasteboardSnapshotTests {
    // A named pasteboard so tests NEVER touch the user's real clipboard.
    @Test func capturesAndRestoresStringContent() {
        let pb = NSPasteboard(name: NSPasteboard.Name("localflow-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pb)
        pb.clearContents()
        pb.setString("transient transcript", forType: .string)

        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "original")
    }
    @Test func restoringEmptyPasteboardClearsIt() {
        let pb = NSPasteboard(name: NSPasteboard.Name("localflow-test-\(UUID().uuidString)"))
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pb)
        pb.setString("junk", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == nil)
    }
}
