import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem
import OSLog

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
    private static let logger = Logger(subsystem: "dev.faintbear.AlexaRemoteBridge", category: "voice-key")
    let mode: VoiceInputMode
    private var active = false
    private var eventSource: CGEventSource?
    private var pendingRelease: Timer?
    private var activeSince: Date?

    init(mode: VoiceInputMode) throws {
        self.mode = mode
    }

    func begin() {
        pendingRelease?.invalidate()
        pendingRelease = nil
        guard !active else { return }
        guard mode == .none || AXIsProcessTrusted() else {
            Self.logger.error("voice shortcut not posted: Accessibility permission is missing for this app identity")
            return
        }
        eventSource = CGEventSource(stateID: .hidSystemState)
        guard mode == .none || eventSource != nil else {
            Self.logger.error("voice shortcut not posted: failed to create HID event source")
            return
        }
        active = true
        activeSince = Date()
        Self.logger.info("posting voice shortcut mode=\(self.mode.rawValue, privacy: .public) phase=down")
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
        let heldMilliseconds = activeSince.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? -1
        Self.logger.notice("voice shortcut release scheduled held_ms=\(heldMilliseconds) delay_ms=180")
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
        let heldMilliseconds = activeSince.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? -1
        Self.logger.notice("voice shortcut released held_ms=\(heldMilliseconds)")
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
        activeSince = nil
        eventSource = nil
    }

    private func tap(keyCode: CGKeyCode, flags: CGEventFlags) {
        post(keyCode: keyCode, down: true, flags: flags)
        post(keyCode: keyCode, down: false, flags: [])
    }

    private func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let source = eventSource ?? CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            Self.logger.error("failed to create voice shortcut event keyCode=\(keyCode)")
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        Self.logger.info("posted voice shortcut keyCode=\(keyCode) down=\(down) flags=\(flags.rawValue)")
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
