import Foundation

/// Pure reducer for the push-to-talk / hands-free gesture protocol.
/// Timestamps are supplied by the caller (testable); no clocks or timers inside.
public struct GestureMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case holdRecording(start: TimeInterval)
        case tapPending(tapEnd: TimeInterval)     // short press; waiting for possible 2nd tap
        case handsFreeRecording
        case handsFreeStopPending                  // stop-tap is down, waiting for its release
    }
    public enum Input: Equatable, Sendable {
        case keyDown(TimeInterval)
        case keyUp(TimeInterval)
        case escape
        case comboCancelled
        case doubleTapTimerFired(TimeInterval)
        case capTimerFired
    }
    public enum Effect: Equatable, Sendable {
        case startCapture
        case stopAndProcess
        case discardCapture
        case scheduleDoubleTapTimer   // fire after doubleTapWindow
    }

    public private(set) var state: State = .idle
    public let shortPressThreshold: TimeInterval
    public let doubleTapWindow: TimeInterval
    public let handsFreeEnabled: Bool

    public var isRecording: Bool {
        switch state {
        case .holdRecording, .tapPending, .handsFreeRecording, .handsFreeStopPending: return true
        case .idle: return false
        }
    }
    public var isHandsFree: Bool {
        switch state {
        case .handsFreeRecording, .handsFreeStopPending: return true
        default: return false
        }
    }

    public init(shortPressThreshold: TimeInterval = 0.3,
                doubleTapWindow: TimeInterval = 0.4,
                handsFreeEnabled: Bool = true) {
        self.shortPressThreshold = shortPressThreshold
        self.doubleTapWindow = doubleTapWindow
        self.handsFreeEnabled = handsFreeEnabled
    }

    public mutating func handle(_ input: Input) -> [Effect] {
        switch (state, input) {
        case (.idle, .keyDown(let t)):
            state = .holdRecording(start: t)
            return [.startCapture]

        case (.holdRecording(let start), .keyUp(let t)):
            if t - start >= shortPressThreshold {
                state = .idle
                return [.stopAndProcess]
            }
            if handsFreeEnabled {
                state = .tapPending(tapEnd: t)
                return [.scheduleDoubleTapTimer]
            }
            state = .idle
            return [.discardCapture]

        case (.tapPending(let tapEnd), .doubleTapTimerFired(let t)) where t - tapEnd >= doubleTapWindow - 0.001:
            state = .idle
            return [.discardCapture]

        case (.tapPending, .keyDown):
            state = .handsFreeRecording   // capture has been running since the first press
            return []

        case (.handsFreeRecording, .keyDown):
            state = .handsFreeStopPending
            return []

        case (.handsFreeStopPending, .keyUp):
            state = .idle
            return [.stopAndProcess]

        case (.holdRecording, .capTimerFired),
             (.tapPending, .capTimerFired),
             (.handsFreeRecording, .capTimerFired),
             (.handsFreeStopPending, .capTimerFired):
            state = .idle
            return [.stopAndProcess]

        case (.holdRecording, .escape), (.holdRecording, .comboCancelled),
             (.tapPending, .escape), (.tapPending, .comboCancelled),
             (.handsFreeRecording, .escape), (.handsFreeRecording, .comboCancelled),
             (.handsFreeStopPending, .escape), (.handsFreeStopPending, .comboCancelled):
            state = .idle
            return [.discardCapture]

        default:
            return []   // ignore (incl. stale doubleTapTimerFired in any other state)
        }
    }
}
