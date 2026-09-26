import AppKit
import CoreGraphics
import Foundation
import OSLog

// HID reports from the AR remote arrive before macOS posts keycode 177.
// Consume that key only in the short window after this remote's mic press.
final class SpotlightSuppressor: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.faintbear.AlexaRemoteBridge", category: "input")
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
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                SpotlightSuppressor.logger.error("event tap disabled; re-enabling")
                if let tap = state.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUserData) == State.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            if (type == .keyDown || type == .keyUp),
               event.getIntegerValueField(.keyboardEventKeycode) == 177 {
                if state.remoteConnected && state.bridgeEnabled {
                    return nil
                }
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
            if let action = state.learningAction {
                state.actionsByKeyCode[keyCode] = action
                state.signaturesByKeyCode[keyCode] = signature
                state.learningAction = nil
                let onButtonLearned = state.onButtonLearned
                state.onButtonLearned = nil
                fputs("remote_button_learning_captured signature=\(signature) keycode=\(keyCode)\n", stderr)
                DispatchQueue.main.async {
                    onButtonLearned?(signature, keyCode, action)
                }
                state.suppressedKeyCodes.insert(keyCode)
                return nil
            }
            guard state.signaturesByKeyCode[keyCode] == signature,
                  let action = state.actionsByKeyCode[keyCode] else {
                return Unmanaged.passUnretained(event)
            }
            state.suppressedKeyCodes.insert(keyCode)
            SpotlightSuppressor.perform(action)
            return nil
        }, userInfo: context) else {
            Unmanaged<State>.fromOpaque(context).release()
            throw SuppressorError.accessibilityRequired
        }
        self.tap = tap
        self.state = state
        state.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private let state: State

    deinit {
        CFMachPortInvalidate(tap)
        Unmanaged.passUnretained(state).release()
    }

    func setRemoteConnected(_ connected: Bool) {
        state.remoteConnected = connected
    }

    func setBridgeEnabled(_ enabled: Bool) {
        state.bridgeEnabled = enabled
    }

    func setMappings(_ mappings: [RemoteButtonMapping]) {
        state.actionsByKeyCode = Dictionary(uniqueKeysWithValues: mappings.map { ($0.keyCode, $0.action) })
        state.signaturesByKeyCode = Dictionary(uniqueKeysWithValues: mappings.map { ($0.keyCode, $0.signature) })
    }

    func noteHardwareButton(signature: String) {
        state.pendingButtonSignature = signature
        state.pendingButtonUntil = Date().timeIntervalSince1970 + 0.25
    }

    func beginButtonLearning(action: RemoteButtonAction,
                             onLearned: @escaping (String, UInt16, RemoteButtonAction) -> Void) {
        state.learningAction = action
        state.onButtonLearned = onLearned
    }

    func cancelReturnButtonLearning() {
        state.learningAction = nil
        state.onButtonLearned = nil
    }

    private static func perform(_ action: RemoteButtonAction) {
        MainActor.assumeIsolated {
            switch action {
            case .sendReturn:
                postReturn()
            case .launchApp(let path):
                let appURL = URL(fileURLWithPath: path)
                if let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier,
                   let runningApp = NSRunningApplication.runningApplications(
                       withBundleIdentifier: bundleIdentifier
                   ).first {
                    runningApp.unhide()
                    _ = runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                    if let error { fputs("mapped_app_open_failed path=\(path) error=\(error)\n", stderr) }
                }
            }
        }
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
    var tap: CFMachPort?
    var remoteConnected = false
    var bridgeEnabled = true
    var pendingButtonSignature: String?
    var pendingButtonUntil: TimeInterval = 0
    var signaturesByKeyCode: [UInt16: String] = [:]
    var actionsByKeyCode: [UInt16: RemoteButtonAction] = [:]
    var suppressedKeyCodes: Set<UInt16> = []
    var learningAction: RemoteButtonAction?
    var onButtonLearned: ((String, UInt16, RemoteButtonAction) -> Void)?
}

private enum SuppressorError: Error {
    case accessibilityRequired
}
