import Testing
@testable import FlowCore

struct GestureMachineTests {
    func machine(handsFree: Bool = true) -> GestureMachine {
        GestureMachine(handsFreeEnabled: handsFree)
    }

    @Test func holdAndReleaseProcesses() {
        var m = machine()
        #expect(m.handle(.keyDown(10.0)) == [.startCapture])
        #expect(m.handle(.keyUp(10.5)) == [.stopAndProcess])   // 0.5s ≥ 0.3s
        #expect(m.state == .idle)
    }
    @Test func shortPressEntersTapPendingThenDiscardsOnTimer() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.keyUp(10.1)) == [.scheduleDoubleTapTimer])  // 0.1s < 0.3s
        #expect(m.state == .tapPending(tapEnd: 10.1))
        #expect(m.handle(.doubleTapTimerFired(10.55)) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func shortPressWithHandsFreeDisabledDiscardsImmediately() {
        var m = machine(handsFree: false)
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.keyUp(10.1)) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func doubleTapEntersHandsFree() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        _ = m.handle(.keyUp(10.1))
        #expect(m.handle(.keyDown(10.3)) == [])                 // within 0.4s window
        #expect(m.state == .handsFreeRecording)
        #expect(m.handle(.keyUp(10.4)) == [])                   // release of 2nd tap ignored
        #expect(m.state == .handsFreeRecording)
    }
    @Test func tapInHandsFreeStopsAndProcesses() {
        var m = machine()
        _ = m.handle(.keyDown(10.0)); _ = m.handle(.keyUp(10.1))
        _ = m.handle(.keyDown(10.3)); _ = m.handle(.keyUp(10.4))   // now hands-free
        #expect(m.handle(.keyDown(20.0)) == [])
        #expect(m.state == .handsFreeStopPending)
        #expect(m.handle(.keyUp(20.1)) == [.stopAndProcess])
        #expect(m.state == .idle)
    }
    @Test func lateDoubleTapTimerInHandsFreeIsIgnored() {
        var m = machine()
        _ = m.handle(.keyDown(10.0)); _ = m.handle(.keyUp(10.1))
        _ = m.handle(.keyDown(10.3))                               // hands-free
        #expect(m.handle(.doubleTapTimerFired(10.5)) == [])        // stale timer
        #expect(m.state == .handsFreeRecording)
    }
    @Test func escapeDiscardsWhileHoldRecording() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.escape) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func escapeDiscardsWhileHandsFree() {
        var m = machine()
        _ = m.handle(.keyDown(10.0)); _ = m.handle(.keyUp(10.1)); _ = m.handle(.keyDown(10.3))
        #expect(m.handle(.escape) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func comboCancelDiscards() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.comboCancelled) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func capTimerProcessesWhileHoldRecording() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.capTimerFired) == [.stopAndProcess])
        #expect(m.state == .idle)
    }
    @Test func capTimerProcessesWhileHandsFree() {
        var m = machine()
        _ = m.handle(.keyDown(10.0)); _ = m.handle(.keyUp(10.1)); _ = m.handle(.keyDown(10.3))
        #expect(m.handle(.capTimerFired) == [.stopAndProcess])
    }
    @Test func inputsInIdleAreIgnored() {
        var m = machine()
        #expect(m.handle(.keyUp(1)) == [])
        #expect(m.handle(.escape) == [])
        #expect(m.handle(.capTimerFired) == [])
        #expect(m.handle(.doubleTapTimerFired(1)) == [])
        #expect(m.state == .idle)
    }
    @Test func isRecordingReflectsState() {
        var m = machine()
        #expect(m.isRecording == false)
        _ = m.handle(.keyDown(10.0))
        #expect(m.isRecording == true)
        #expect(m.isHandsFree == false)
        _ = m.handle(.keyUp(10.1)); _ = m.handle(.keyDown(10.3))
        #expect(m.isRecording == true)
        #expect(m.isHandsFree == true)
    }
}
