import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

// HID reports from the AR remote arrive before macOS posts keycode 177.
// Consume that key only in the short window after this remote's mic press.
final class SpotlightSuppressor: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.faintbear.AlexaRemoteBridge", category: "input")
    private static let focusRetryLimit = 12
    private static let manualAccessibilityAttribute = "AXManualAccessibility"
    private static let enhancedAccessibilityAttribute = "AXEnhancedUserInterface"
    private static let focusDiagnosticDefaultsKey = "lastMappedAppFocusDiagnostic"
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
                openAppAndFocusInput(path: path)
            }
        }
    }

    private static func openAppAndFocusInput(path: String) {
        let appURL = URL(fileURLWithPath: path)
        let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier
        if let bundleIdentifier,
           let runningApp = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleIdentifier
           ).first {
            runningApp.unhide()
            _ = runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            focusInputAfterActivation(processIdentifier: runningApp.processIdentifier)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
            if let error {
                fputs("mapped_app_open_failed path=\(path) error=\(error)\n", stderr)
                return
            }
            guard let application else { return }
            focusInputAfterActivation(processIdentifier: application.processIdentifier)
        }
    }

    private static func focusInputAfterActivation(processIdentifier: pid_t) {
        focusInputAfterActivation(processIdentifier: processIdentifier, attempt: 0, didClickEditor: false)
    }

    private static func focusInputAfterActivation(processIdentifier: pid_t, attempt: Int,
                                                  didClickEditor: Bool) {
        // Web/Electron apps may build their AX tree only after an assistive client
        // announces itself. Keep scanning briefly while the app's editor mounts.
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.35 : 0.25)) {
            guard AXIsProcessTrusted() else {
                recordFocusDiagnostic("Failed · Accessibility permission is not granted · pid=\(processIdentifier)")
                return
            }

            let application = NSRunningApplication(processIdentifier: processIdentifier)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != processIdentifier {
                _ = application?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                guard attempt + 1 < focusRetryLimit else {
                    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                    recordFocusDiagnostic("Failed · Target app did not become frontmost · target_pid=\(processIdentifier) frontmost_pid=\(frontmostPID)")
                    return
                }
                focusInputAfterActivation(processIdentifier: processIdentifier, attempt: attempt + 1,
                                          didClickEditor: didClickEditor)
                return
            }

            let appElement = AXUIElementCreateApplication(processIdentifier)
            let manualResult = AXUIElementSetAttributeValue(
                appElement,
                manualAccessibilityAttribute as CFString,
                kCFBooleanTrue
            )
            var fallbackResult: AXError?
            if manualResult == .attributeUnsupported {
                fallbackResult = AXUIElementSetAttributeValue(
                    appElement,
                    enhancedAccessibilityAttribute as CFString,
                    kCFBooleanTrue
                )
            }

            let windows = applicationWindows(appElement)
            var candidateCount = 0
            var allCandidates: [(element: AXUIElement, role: String, score: Int)] = []
            for window in windows {
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                let candidates = focusableTextInputs(under: window, windowFrame: accessibilityFrame(of: window))
                    .sorted { $0.score > $1.score }
                candidateCount += candidates.count
                allCandidates.append(contentsOf: candidates)
                for candidate in candidates {
                    if focusAccessibilityElement(candidate.element, applicationElement: appElement) {
                        if !didClickEditor, clickAccessibilityElement(candidate.element) {
                            recordFocusDiagnostic("Editor click sent · bundle=\(application?.bundleIdentifier ?? "unknown") · role=\(candidate.role) · score=\(candidate.score) · attempt=\(attempt + 1)/\(focusRetryLimit)")
                            focusInputAfterActivation(processIdentifier: processIdentifier,
                                                      attempt: attempt + 1,
                                                      didClickEditor: true)
                            return
                        }
                        recordFocusDiagnostic("AX focus confirmed · bundle=\(application?.bundleIdentifier ?? "unknown") · role=\(candidate.role) · score=\(candidate.score) · attempt=\(attempt + 1)/\(focusRetryLimit)")
                        return
                    }
                }
            }

            // If AX focus is accepted but does not place the insertion point, click
            // the best-scoring editor once as a final fallback.
            if !didClickEditor, attempt == 1,
               let candidate = allCandidates.sorted(by: { $0.score > $1.score }).first,
               clickAccessibilityElement(candidate.element) {
                recordFocusDiagnostic("AX focus unconfirmed; editor click sent · bundle=\(application?.bundleIdentifier ?? "unknown") · role=\(candidate.role) · score=\(candidate.score) · windows=\(windows.count) · candidates=\(candidateCount)")
                focusInputAfterActivation(processIdentifier: processIdentifier,
                                          attempt: attempt + 1,
                                          didClickEditor: true)
                return
            }

            guard attempt + 1 < focusRetryLimit else {
                let reason = candidateCount == 0 ? "no_focusable_text_input" : "focus_not_confirmed"
                recordFocusDiagnostic("Failed · \(reason) · bundle=\(application?.bundleIdentifier ?? "unknown") · windows=\(windows.count) · candidates=\(candidateCount) · AXManualAccessibility=\(manualResult.rawValue) · AXEnhancedUserInterface=\(fallbackResult?.rawValue ?? -1) · attempt=\(attempt + 1)/\(focusRetryLimit)")
                return
            }
            focusInputAfterActivation(processIdentifier: processIdentifier, attempt: attempt + 1,
                                      didClickEditor: didClickEditor)
        }
    }

    private static func recordFocusDiagnostic(_ message: String) {
        UserDefaults.standard.set(message, forKey: focusDiagnosticDefaultsKey)
        logger.error("mapped_app_focus \(message, privacy: .public)")
        fputs("mapped_app_focus \(message)\n", stderr)
    }

    private static func focusAccessibilityElement(_ element: AXUIElement,
                                                  applicationElement: AXUIElement) -> Bool {
        if accessibilityElementIsFocused(element, applicationElement: applicationElement) {
            return true
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(applicationElement,
                                         kAXFocusedUIElementAttribute as CFString,
                                         element)
        if accessibilityElementIsFocused(element, applicationElement: applicationElement) {
            return true
        }
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return accessibilityElementIsFocused(element, applicationElement: applicationElement)
    }

    private static func accessibilityElementIsFocused(_ element: AXUIElement,
                                                       applicationElement: AXUIElement) -> Bool {
        var elementFocusedValue: CFTypeRef?
        let elementFocused = AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString,
                                                           &elementFocusedValue) == .success &&
            (elementFocusedValue as? NSNumber)?.boolValue == true
        var applicationFocusedValue: CFTypeRef?
        let applicationFocusedMatches: Bool
        if AXUIElementCopyAttributeValue(applicationElement, kAXFocusedUIElementAttribute as CFString,
                                         &applicationFocusedValue) == .success,
           let applicationFocusedValue {
            applicationFocusedMatches = CFEqual(applicationFocusedValue, element)
        } else {
            applicationFocusedMatches = false
        }
        return elementFocused || applicationFocusedMatches
    }

    private static func clickAccessibilityElement(_ element: AXUIElement) -> Bool {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
                                            &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                            &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return false }

        let position = unsafeDowncast(positionValue, to: AXValue.self)
        let size = unsafeDowncast(sizeValue, to: AXValue.self)
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0,
              let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let point = CGPoint(x: origin.x + dimensions.width / 2,
                            y: origin.y + dimensions.height / 2)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func applicationWindows(_ appElement: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute, kAXWindowsAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value) == .success,
                  let value else { continue }
            let discovered: [AXUIElement]
            if attribute == kAXWindowsAttribute as String {
                discovered = value as? [AXUIElement] ?? []
            } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                discovered = [unsafeDowncast(value, to: AXUIElement.self)]
            } else {
                discovered = []
            }
            for window in discovered where !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        return windows
    }

    private static func focusableTextInputs(under root: AXUIElement,
                                            windowFrame: CGRect?) -> [(element: AXUIElement, role: String, score: Int)] {
        var candidates: [(element: AXUIElement, role: String, score: Int)] = []
        var stack: [(element: AXUIElement, context: String, depth: Int)] = [(root, semanticText(of: root), 0)]
        var visited: [AXUIElement] = []
        var inspected = 0
        let childAttributes = ["AXChildrenInNavigationOrder", kAXVisibleChildrenAttribute,
                               kAXContentsAttribute, kAXChildrenAttribute]

        while let current = stack.popLast(), inspected < 5_000 {
            if visited.contains(where: { CFEqual($0, current.element) }) { continue }
            visited.append(current.element)
            inspected += 1
            guard current.depth < 30 else { continue }
            if let role = stringAttribute(kAXRoleAttribute, of: current.element),
               role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
                var enabledValue: CFTypeRef?
                let enabledResult = AXUIElementCopyAttributeValue(current.element,
                                                                  kAXEnabledAttribute as CFString,
                                                                  &enabledValue)
                let enabled = enabledResult != .success || (enabledValue as? NSNumber)?.boolValue == true
                if enabled {
                    let ownText = semanticText(of: current.element)
                    let candidateContext = [current.context, ownText].filter { !$0.isEmpty }.joined(separator: " ")
                    let score = composerScore(role: role, semanticText: candidateContext,
                                              frame: accessibilityFrame(of: current.element),
                                              windowFrame: windowFrame)
                    if score > 0 { candidates.append((current.element, role, score)) }
                }
            }

            let nextContext = String(([current.context, semanticText(of: current.element)]
                .filter { !$0.isEmpty }.joined(separator: " ")).suffix(512))
            var children: [AXUIElement] = []
            for attribute in childAttributes {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current.element, attribute as CFString, &value) == .success,
                      let childElements = value as? [AXUIElement] else { continue }
                for child in childElements where !children.contains(where: { CFEqual($0, child) }) {
                    children.append(child)
                }
            }
            stack.append(contentsOf: children.reversed().map { ($0, nextContext, current.depth + 1) })
        }
        return candidates
    }

    private static func semanticText(of element: AXUIElement) -> String {
        let attributes = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                          kAXHelpAttribute, kAXPlaceholderValueAttribute]
        return attributes.compactMap { stringAttribute($0, of: element) }
            .joined(separator: " ").lowercased()
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
                                            &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                            &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = unsafeDowncast(positionValue, to: AXValue.self)
        let size = unsafeDowncast(sizeValue, to: AXValue.self)
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else {
            return nil
        }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func composerScore(role: String, semanticText: String,
                                      frame: CGRect?, windowFrame: CGRect?) -> Int {
        let excluded = ["password", "api key", "token", "rename", "title", "code editor", "search",
                        "密码", "密钥", "令牌", "重命名", "搜索"]
        guard !excluded.contains(where: semanticText.contains) else { return 0 }
        let strong = ["composer", "prompt-editor", "prompt_editor", "chat-input", "chat_input",
                      "message-input", "message_input", "prompt input", "message input", "输入消息", "消息输入"]
        let supporting = ["message", "prompt", "reply", "ask", "chat", "提问", "回复", "发送消息"]
        var score = role == kAXTextAreaRole as String ? 30 : 0
        if strong.contains(where: semanticText.contains) { score += 100 }
        else if supporting.contains(where: semanticText.contains) { score += 60 }
        if let frame {
            if frame.width >= 280 { score += 20 }
            if (24...500).contains(frame.height) { score += 10 }
            if let windowFrame, windowFrame.width > 0, windowFrame.height > 0 {
                if frame.width / windowFrame.width >= 0.45 { score += 25 }
                let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
                if verticalPosition >= 0.55 { score += 20 }
                else if verticalPosition <= 0.25 { score -= 15 }
            }
        }
        return score >= 60 ? score : 0
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
