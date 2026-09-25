import CoreGraphics
import Foundation

// HID reports from the AR remote arrive before macOS posts keycode 177.
// Consume that key only in the short window after this remote's mic press.
final class SpotlightSuppressor: @unchecked Sendable {
    private let tap: CFMachPort

    init() throws {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue)
        // A temporary instance is needed because the C callback receives its context at creation.
        let state = State()
        let context = Unmanaged.passRetained(state).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
            if (type == .keyDown || type == .keyUp),
               event.getIntegerValueField(.keyboardEventKeycode) == 177 {
                let shouldSuppress = state.micHeld || Date().timeIntervalSince1970 <= state.windowUntil
                if shouldSuppress { return nil }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            Unmanaged<State>.fromOpaque(context).release()
            throw SuppressorError.accessibilityRequired
        }
        self.tap = tap
        self.state = state
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private let state: State

    deinit {
        CFMachPortInvalidate(tap)
        Unmanaged.passUnretained(state).release()
    }

    func noteMicPress() {
        state.micHeld = true
        state.windowUntil = Date().timeIntervalSince1970 + 0.3
    }

    func noteMicRelease() {
        state.micHeld = false
        state.windowUntil = Date().timeIntervalSince1970 + 0.3
    }
}

private final class State: @unchecked Sendable {
    var micHeld = false
    var windowUntil: TimeInterval = 0
}

private enum SuppressorError: Error {
    case accessibilityRequired
}
