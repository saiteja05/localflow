import AppKit
import CoreGraphics

/// Owns the CGEventTap. All interpretation is delegated to KeyEventInterpreter;
/// this class only bridges CGEvents in and HotkeyRawEvents out.
public final class EventTapHotkeySource: HotkeySource, @unchecked Sendable {
    public let events: AsyncStream<HotkeyRawEvent>
    private let continuation: AsyncStream<HotkeyRawEvent>.Continuation
    private let lock = NSLock()
    private var interpreter: KeyEventInterpreter
    private var currentChoice: HotkeyChoice
    private var tap: CFMachPort?
    private var secureInputTimer: Timer?
    private var lastSecureInput = false

    public init(choice: HotkeyChoice) {
        self.interpreter = KeyEventInterpreter(choice: choice)
        self.currentChoice = choice
        (events, continuation) = AsyncStream.makeStream(of: HotkeyRawEvent.self)
    }

    public func updateChoice(_ choice: HotkeyChoice) {
        lock.lock(); defer { lock.unlock() }
        interpreter = KeyEventInterpreter(choice: choice)
        currentChoice = choice
    }

    public enum TapError: Error { case creationFailed /* Accessibility not granted, usually */ }

    public func start() throws {
        guard tap == nil else { return }   // idempotent: no duplicate taps or timers
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,             // active: lets us swallow the Fn press
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let source = Unmanaged<EventTapHotkeySource>
                    .fromOpaque(userInfo!).takeUnretainedValue()
                return source.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { throw TapError.creationFailed }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Poll Secure Event Input (no notification API exists for it).
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let active = Permissions.isSecureInputActive
            if active != self.lastSecureInput {
                self.lastSecureInput = active
                self.continuation.yield(.secureInputChanged(active))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        secureInputTimer = timer
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables taps that stall or after user-input protection; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Never feed autorepeat events to the interpreter.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            // OS key-repeat is synthesized below the tap; the interpreter would
            // read it as combo-cancel. Swallow repeats of our own held custom key,
            // pass all other repeats through untouched.
            lock.lock()
            let holdingOurKey: Bool
            if case .custom(let kc, _) = currentChoice, interpreter.isHolding,
               UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == kc {
                holdingOurKey = true
            } else {
                holdingOurKey = false
            }
            lock.unlock()
            return holdingOurKey ? nil : Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let input: KeyEventInterpreter.CGInput
        switch type {
        case .flagsChanged: input = .flagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown:      input = .keyDown(keyCode: keyCode, flags: flags)
        case .keyUp:        input = .keyUp(keyCode: keyCode, flags: flags)
        default:            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let output = interpreter.interpret(input)
        lock.unlock()
        if let e = output.event { continuation.yield(e) }
        return output.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
