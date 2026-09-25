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
            if event.getIntegerValueField(.eventSourceUserData) == State.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            if (type == .keyDown || type == .keyUp),
               event.getIntegerValueField(.keyboardEventKeycode) == 177 {
                let shouldSuppress = state.micHeld || Date().timeIntervalSince1970 <= state.windowUntil
                if shouldSuppress { return nil }
            }
            guard type == .keyDown || type == .keyUp else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let now = Date().timeIntervalSince1970
            if type == .keyUp, state.suppressedKeyCodes.remove(keyCode) != nil {
                return nil
            }
            guard type == .keyDown, let signature = state.pendingButtonSignature,
                  now <= state.pendingButtonUntil else {
                return Unmanaged.passUnretained(event)
            }
            state.pendingButtonSignature = nil
            if state.isLearningReturn {
                state.returnKeyCodes[keyCode] = signature
                state.isLearningReturn = false
                state.onReturnLearned?(signature, keyCode)
                state.suppressedKeyCodes.insert(keyCode)
                return nil
            }
            guard state.returnKeyCodes[keyCode] == signature else {
                return Unmanaged.passUnretained(event)
            }
            state.suppressedKeyCodes.insert(keyCode)
            SpotlightSuppressor.postReturn()
            return nil
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

    func setReturnMappings(_ mappings: [UInt16: String]) {
        state.returnKeyCodes = mappings
    }

    func noteHardwareButton(signature: String) {
        state.pendingButtonSignature = signature
        state.pendingButtonUntil = Date().timeIntervalSince1970 + 0.25
    }

    func beginReturnButtonLearning(onLearned: @escaping (String, UInt16) -> Void) {
        state.isLearningReturn = true
        state.onReturnLearned = onLearned
    }

    func cancelReturnButtonLearning() {
        state.isLearningReturn = false
        state.onReturnLearned = nil
    }

    private static func postReturn() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: State.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: State.syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private final class State: @unchecked Sendable {
    static let syntheticEventMarker: Int64 = 0x41524D4150504544
    var micHeld = false
    var windowUntil: TimeInterval = 0
    var pendingButtonSignature: String?
    var pendingButtonUntil: TimeInterval = 0
    var returnKeyCodes: [UInt16: String] = [:]
    var suppressedKeyCodes: Set<UInt16> = []
    var isLearningReturn = false
    var onReturnLearned: ((String, UInt16) -> Void)?
}

private enum SuppressorError: Error {
    case accessibilityRequired
}
