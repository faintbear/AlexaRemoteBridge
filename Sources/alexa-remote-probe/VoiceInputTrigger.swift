import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem

enum VoiceInputMode: String {
    case none
    case fnHold = "fn-hold"
    case fnToggle = "fn-toggle"
    case leftOptionHold = "left-option-hold"
    case rightOptionHold = "right-option-hold"

    init(argument: String) throws {
        guard let value = Self(rawValue: argument) else {
            throw VoiceInputTriggerError.invalidMode(argument)
        }
        self = value
    }
}

/// Pairs a remote microphone session with the shortcut expected by an existing
/// dictation app. This only posts keys; the app itself performs transcription.
// All operations are confined to the HID callback's run loop.
final class VoiceInputTrigger: @unchecked Sendable {
    let mode: VoiceInputMode
    private var active = false
    private var pendingRelease: Timer?

    init(mode: VoiceInputMode) throws {
        self.mode = mode
    }

    func begin() {
        pendingRelease?.invalidate()
        pendingRelease = nil
        guard !active else { return }
        guard mode == .none || AXIsProcessTrusted() else { return }
        active = true
        switch mode {
        case .none:
            break
        case .fnHold:
            post(keyCode: 63, down: true, flags: .maskSecondaryFn)
        case .fnToggle:
            tap(keyCode: 63, flags: .maskSecondaryFn)
        case .leftOptionHold:
            post(keyCode: 58, down: true,
                 flags: [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))])
        case .rightOptionHold:
            post(keyCode: 61, down: true,
                 flags: [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))])
        }
    }

    /// BlackHole receives scheduled audio after the HID release callback. Keep
    /// the dictation shortcut open briefly so the last audio buffer is heard.
    func end() {
        guard active else { return }
        pendingRelease?.invalidate()
        pendingRelease = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            self?.releaseNow()
        }
    }

    func cancel() {
        pendingRelease?.invalidate()
        pendingRelease = nil
        releaseNow()
    }

    private func releaseNow() {
        guard active else { return }
        active = false
        switch mode {
        case .none:
            break
        case .fnHold:
            post(keyCode: 63, down: false, flags: [])
        case .fnToggle:
            tap(keyCode: 63, flags: .maskSecondaryFn)
        case .leftOptionHold:
            post(keyCode: 58, down: false, flags: [])
        case .rightOptionHold:
            post(keyCode: 61, down: false, flags: [])
        }
    }

    private func tap(keyCode: CGKeyCode, flags: CGEventFlags) {
        post(keyCode: keyCode, down: true, flags: flags)
        post(keyCode: keyCode, down: false, flags: [])
    }

    private func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

enum VoiceInputTriggerError: Error, CustomStringConvertible {
    case accessibilityRequired
    case invalidMode(String)

    var description: String {
        switch self {
        case .accessibilityRequired:
            return "Voice input shortcut requires Accessibility permission for this app or terminal"
        case .invalidMode(let value):
            return "Unknown voice key mode '\(value)'; use none, fn-hold, fn-toggle, left-option-hold, or right-option-hold"
        }
    }
}
