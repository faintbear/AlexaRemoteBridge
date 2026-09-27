import AppKit
import Foundation
import IOKit.hid
import OSLog

private let amazonVendorID = 0x0171
private let alexaRemoteProductID = 0x041E
private let maximumReportLength = 512

private func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func hexPrefix(_ bytes: UnsafePointer<UInt8>, length: Int, limit: Int = 8) -> String {
    let count = min(length, limit)
    return (0..<count).map { String(format: "%02X", bytes[$0]) }.joined(separator: " ")
}

// HID callbacks and the safety timer are scheduled on the same run loop.
@MainActor private final class Probe: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.faintbear.AlexaRemoteBridge", category: "remote-hid")
    private lazy var manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private let seize = CommandLine.arguments.contains("--seize")
    private let audioTest = CommandLine.arguments.contains("--audio-test")
    private let appMode = CommandLine.arguments.contains("--app") || Bundle.main.bundleURL.pathExtension == "app"
    private var liveMode: Bool { appMode || CommandLine.arguments.contains("--live") }
    private var recorder: OpusRecorder?
    private var liveOutput: LiveAudioOutput?
    private var voiceInputTrigger: VoiceInputTrigger?
    private var spotlightSuppressor: SpotlightSuppressor?
    private var menuBar: MenuBarApp?
    private var remote: IOHIDDevice?
    private var streaming = false
    private var micButtonDown = false
    private var micPressStartedAt: TimeInterval?
    private var pendingMicRelease: Timer?
    private var bridgeEnabled = true
    private var learningAction = false
    private var pendingLearningAction: RemoteButtonAction?
    private var hidExecutionTimes: [String: TimeInterval] = [:]
    private let hidOnlyDebounceInterval: TimeInterval = 0.35
    private var buttonMappings: [RemoteButtonMapping] = []
    private var detectedButtons: [DetectedRemoteButton] = []
    private var permissionNotice: String?
    private var inputMonitoringStatus: PermissionStatus = .notGranted
    private var inputMonitoringManagerOpened = false
    private var accessibilityStatus: PermissionStatus = .notGranted
    private var audioFrames = 0
    private var safetyTimer: Timer?
    private var permissionRefreshTimer: Timer?

    isolated deinit {
        for buffer in buffers.values {
            buffer.deallocate()
        }
    }

    func run() throws {
        let application = appMode ? NSApplication.shared : nil
        application?.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--record-wav") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw ProbeError.missingOutputPath
            }
            recorder = try OpusRecorder(path: CommandLine.arguments[index + 1])
        }
        if liveMode {
            if recorder == nil { recorder = try OpusRecorder(path: nil) }
            let voiceMode = try Self.selectedVoiceMode()
            voiceInputTrigger = try VoiceInputTrigger(mode: voiceMode)
            if appMode && !AXIsProcessTrusted() {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            loadReturnMappings()
            rebuildSpotlightSuppressorIfNeeded()
        }
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: amazonVendorID,
            kIOHIDProductIDKey as String: alexaRemoteProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let options = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
        let result = IOHIDManagerOpen(manager, options)
        inputMonitoringManagerOpened = result == kIOReturnSuccess
        updatePermissionStatuses(retryManagerOpen: false)
        if result != kIOReturnSuccess, !appMode {
            throw ProbeError.openFailed(result)
        }

        print("\(timestamp()) probe_started vid=0x0171 pid=0x041E mode=\(liveMode ? "live" : (recorder != nil ? "record_wav" : (audioTest ? "audio_test" : (seize ? "exclusive" : "read_only"))))")
        if seize { print("Other AR remote buttons are temporarily unavailable to macOS until this process stops.") }
        if audioTest || recorder != nil { print("The probe sends only HID output report F2=01 on mic press and F2=00 on release.") }
        if CommandLine.arguments.contains("--record-wav") { print("Audio is saved locally as 16 kHz mono PCM WAV after mic release.") }
        if liveMode {
            print("Audio is sent to BlackHole 2ch; select BlackHole 2ch as the microphone in the receiving app.")
            print("voice_key_mode=\(voiceInputTrigger?.mode.rawValue ?? "none")")
            print("accessibility_trusted=\(AXIsProcessTrusted()) spotlight_suppressor=\(spotlightSuppressor != nil)")
        }
        print("Press ordinary buttons, then hold the Alexa button and speak. Press Control-C to stop.")
        if let application {
            menuBar = MenuBarApp(mode: voiceInputTrigger?.mode ?? .none,
                                 onToggle: { [weak self] in self?.toggleBridge() ?? false },
                                 onModeChange: { [weak self] mode in try self?.changeVoiceMode(mode) },
                                 onLearnAction: { [weak self] action in self?.beginButtonLearning(action: action) },
                                 onChooseApp: { [weak self] path in self?.beginButtonLearning(action: .launchApp(path: path)) },
                                 onClearMappings: { [weak self] in self?.clearButtonMappings() },
                                 onRemoveMapping: { [weak self] index in self?.removeButtonMapping(at: index) },
                                 onTestAction: { action in SpotlightSuppressor.perform(action) },
                                 onCancelLearning: { [weak self] in self?.cancelButtonLearning() },
                                 onQuit: { [weak self] in self?.stop() })
            refreshMenu()
            // Recheck TCC and runtime readiness while the app runs so returning from
            // System Settings updates permission indicators without a manual refresh.
            permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
            application.run()
        } else {
            RunLoop.current.run()
        }
    }

    private static func selectedVoiceMode() throws -> VoiceInputMode {
        guard let index = CommandLine.arguments.firstIndex(of: "--voice-key") else {
            if (CommandLine.arguments.contains("--app") || Bundle.main.bundleURL.pathExtension == "app"),
               let saved = UserDefaults.standard.string(forKey: "voiceInputMode"),
               let mode = VoiceInputMode(rawValue: saved) { return mode }
            return (CommandLine.arguments.contains("--app") || Bundle.main.bundleURL.pathExtension == "app")
                ? .leftOptionHold : .none
        }
        guard CommandLine.arguments.indices.contains(index + 1) else {
            throw ProbeError.missingVoiceMode
        }
        return try VoiceInputMode(argument: CommandLine.arguments[index + 1])
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard buffers[device] == nil else { return }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maximumReportLength)
        buffer.initialize(repeating: 0, count: maximumReportLength)
        buffers[device] = buffer
        remote = device

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, maximumReportLength, { context, _, _, _, reportID, report, reportLength in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
                    .received(reportID: reportID, bytes: report, length: reportLength)
            }
        }, context)

        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "unknown"
        print("\(timestamp()) device_matched product=\(product) transport=\(transport)")
        spotlightSuppressor?.setRemoteConnected(true)
        refreshMenu()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        if remote == device {
            pendingMicRelease?.invalidate()
            pendingMicRelease = nil
            if streaming { setAudio(enabled: false) }
            remote = nil
            streaming = false
            micButtonDown = false
            micPressStartedAt = nil
            spotlightSuppressor?.setRemoteConnected(false)
            voiceInputTrigger?.cancel()
            safetyTimer?.invalidate()
        }
        if let buffer = buffers.removeValue(forKey: device) {
            buffer.deallocate()
        }
        print("\(timestamp()) device_removed")
        refreshMenu()
    }

    private func received(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let safeLength = max(0, Int(length))
        if reportID != 0xF0, safeLength >= 3 {
            let usage = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            let hasButtonPayload = (1..<safeLength).contains { bytes[$0] != 0 }
            if hasButtonPayload {
                let signature = String(format: "%02X:%02X:%02X", reportID, bytes[1], bytes[2])
                let remoteButton = RemoteButtonKey.resolve(reportID: reportID, usage: usage)
                let isMicrophone = remoteButton == .microphone || (reportID == 2 && usage == 0x0221)
                if let remoteButton, remoteButton != .microphone, !isMicrophone {
                    if learningAction {
                        if let action = pendingLearningAction {
                            finishButtonLearning(signature: signature, keyCode: nil, action: action)
                        }
                    } else if bridgeEnabled,
                              let mapping = buttonMappings.first(where: {
                                  $0.signature == signature && $0.keyCode == nil
                              }) {
                        let now = Date().timeIntervalSince1970
                        let lastExecution = hidExecutionTimes[signature] ?? 0
                        if now - lastExecution >= hidOnlyDebounceInterval {
                            hidExecutionTimes[signature] = now
                            SpotlightSuppressor.perform(mapping.action)
                        }
                    }
                    spotlightSuppressor?.noteHardwareButton(signature: signature)
                } else if !isMicrophone {
                    spotlightSuppressor?.noteHardwareButton(signature: signature)
                }
                let payload = (0..<safeLength).map { String(format: "%02X", bytes[$0]) }.joined(separator: " ")
                recordDetectedButton(signature: String(format: "report %02X · %@", reportID, payload),
                                     keyCode: nil,
                                     remoteButton: remoteButton)
            }
        }
        if bridgeEnabled && (audioTest || recorder != nil), reportID == 2, safeLength >= 3 {
            let usage = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            if usage == 0x0221 {
                if pendingMicRelease != nil {
                    Self.logger.notice("remote mic release cancelled: press resumed")
                    print("\(timestamp()) remote_mic_release_cancelled reason=press_resumed")
                    pendingMicRelease?.invalidate()
                    pendingMicRelease = nil
                }
                if !micButtonDown {
                    micButtonDown = true
                    micPressStartedAt = Date().timeIntervalSince1970
                    Self.logger.notice("remote mic down")
                    print("\(timestamp()) remote_mic_down suppressor_ready=\(spotlightSuppressor != nil)")
                    fflush(stdout)
                    if !streaming { setAudio(enabled: true) }
                }
            }
            if usage == 0, micButtonDown, pendingMicRelease == nil {
                let heldFor = micPressStartedAt.map { Int((Date().timeIntervalSince1970 - $0) * 1_000) } ?? -1
                Self.logger.notice("remote mic release candidate held_ms=\(heldFor) debounce_ms=450")
                print("\(timestamp()) remote_mic_release_candidate held_ms=\(heldFor) debounce_ms=450")
                fflush(stdout)
                pendingMicRelease = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.micButtonDown else { return }
                        let confirmedHold = self.micPressStartedAt.map { Int((Date().timeIntervalSince1970 - $0) * 1_000) } ?? -1
                        Self.logger.notice("remote mic up confirmed held_ms=\(confirmedHold)")
                        print("\(timestamp()) remote_mic_up_confirmed held_ms=\(confirmedHold)")
                        fflush(stdout)
                        self.pendingMicRelease = nil
                        self.micButtonDown = false
                        self.micPressStartedAt = nil
                        if self.streaming { self.setAudio(enabled: false) }
                    }
                }
            }
        }
        if reportID == 0xF0 {
            audioFrames += 1
            if recorder != nil, safeLength == 81 {
                if let samples = recorder?.appendFrame(UnsafePointer(bytes + 1), count: 80) {
                    liveOutput?.append(samples)
                }
            }
            if audioFrames == 1 || audioFrames % 50 == 0 {
                print("\(timestamp()) audio_frame count=\(audioFrames) length=\(safeLength)")
                fflush(stdout)
            }
            if audioFrames == 1 { refreshMenu() }
            return
        }
        let prefix = hexPrefix(UnsafePointer(bytes), length: safeLength)
        print("\(timestamp()) input report=0x\(String(format: "%02X", reportID)) length=\(safeLength) prefix=\(prefix)")
        fflush(stdout)
    }

    private func setAudio(enabled: Bool) {
        guard let remote else { return }
        if enabled, liveMode, liveOutput == nil {
            do {
                liveOutput = try LiveAudioOutput(deviceName: "BlackHole 2ch")
            } catch {
                permissionNotice = "音频输出初始化失败：\(error.localizedDescription)"
                fputs("live_output_init_failed error=\(error)\n", stderr)
                refreshMenu()
                return
            }
        }
        let report: [UInt8] = [0xF2, enabled ? 0x01 : 0x00]
        let result = report.withUnsafeBufferPointer { pointer in
            IOHIDDeviceSetReport(remote, kIOHIDReportTypeOutput, 0xF2, pointer.baseAddress!, report.count)
        }
        Self.logger.notice("audio command enabled=\(enabled) result=\(result) frames=\(self.audioFrames)")
        print("\(timestamp()) audio_\(enabled ? "start" : "stop") result=0x\(String(format: "%08X", UInt32(bitPattern: result))) frames=\(audioFrames)")
        fflush(stdout)
        guard result == kIOReturnSuccess else {
            if !enabled { voiceInputTrigger?.cancel() }
            return
        }
        streaming = enabled
        safetyTimer?.invalidate()
        if enabled {
            audioFrames = 0
            recorder?.start()
            liveOutput?.start()
            voiceInputTrigger?.begin()
            safetyTimer = Timer.scheduledTimer(withTimeInterval: liveMode ? 30 : 10, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.streaming else { return }
                    print("\(timestamp()) safety_timeout")
                    self.micButtonDown = false
                    self.setAudio(enabled: false)
                }
            }
        } else {
            liveOutput?.finish()
            voiceInputTrigger?.end()
            do { try recorder?.finish() }
            catch { fputs("wav_save_failed error=\(error)\n", stderr) }
        }
        refreshMenu()
    }

    private func refreshMenu() {
        menuBar?.update(connected: remote != nil, speaking: streaming, enabled: bridgeEnabled,
                        learningAction: learningAction, mappingCount: buttonMappings.count,
                        canLearnReturn: spotlightSuppressor != nil,
                        permissionNotice: permissionNotice, mappings: buttonMappings,
                        detectedButtons: detectedButtons,
                        inputMonitoringStatus: inputMonitoringStatus,
                        accessibilityStatus: accessibilityStatus)
    }

    private func rebuildSpotlightSuppressorIfNeeded() {
        guard liveMode, AXIsProcessTrusted(), spotlightSuppressor == nil else { return }
        do {
            let suppressor = try SpotlightSuppressor()
            suppressor.setMappings(buttonMappings)
            suppressor.setRemoteConnected(remote != nil)
            suppressor.setBridgeEnabled(bridgeEnabled)
            spotlightSuppressor = suppressor
            print("spotlight_suppression_ready scope=AR_mic_hold_plus_300ms")
        } catch {
            fputs("warning: Spotlight suppression is not ready; live audio will still run\n", stderr)
        }
    }

    private func updatePermissionStatuses(retryManagerOpen: Bool) {
        let tccGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if retryManagerOpen, tccGranted, !inputMonitoringManagerOpened {
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            inputMonitoringManagerOpened = result == kIOReturnSuccess
        }
        if !tccGranted {
            inputMonitoringStatus = .notGranted
        } else if inputMonitoringManagerOpened {
            inputMonitoringStatus = .granted
        } else {
            inputMonitoringStatus = .needsRestart
        }

        rebuildSpotlightSuppressorIfNeeded()
        if !AXIsProcessTrusted() {
            accessibilityStatus = .notGranted
        } else if spotlightSuppressor != nil {
            accessibilityStatus = .granted
        } else {
            accessibilityStatus = .needsRestart
        }
        permissionNotice = permissionNoticeForCurrentStatuses()
    }

    private func permissionNoticeForCurrentStatuses() -> String? {
        switch inputMonitoringStatus {
        case .notGranted:
            return "请在输入监控设置中授权 AlexaRemoteBridge"
        case .needsRestart:
            return "输入监控已授权但运行时尚未就绪，请完全退出并重新打开 App"
        case .granted:
            switch accessibilityStatus {
            case .notGranted:
                return "需要辅助功能授权以执行按键映射和聚焦输入框"
            case .needsRestart:
                return "辅助功能已授权但运行时尚未就绪，请完全退出并重新打开 App"
            case .granted:
                return nil
            }
        }
    }

    private func refreshPermissions() {
        let previousInputMonitoring = inputMonitoringStatus
        let previousAccessibility = accessibilityStatus
        let previousNotice = permissionNotice
        updatePermissionStatuses(retryManagerOpen: true)
        guard previousInputMonitoring != inputMonitoringStatus ||
              previousAccessibility != accessibilityStatus ||
              previousNotice != permissionNotice else { return }
        refreshMenu()
    }

    private func recordDetectedButton(signature: String, keyCode: UInt16?, remoteButton: RemoteButtonKey?) {
        let now = Date()
        if let last = detectedButtons.first,
           last.signature == signature,
           now.timeIntervalSince(last.detectedAt) < 1.0 { return }
        detectedButtons.insert(DetectedRemoteButton(signature: signature,
                                                    keyCode: keyCode,
                                                    remoteButton: remoteButton,
                                                    detectedAt: now), at: 0)
        if detectedButtons.count > 12 { detectedButtons.removeLast(detectedButtons.count - 12) }
        print("remote_button_detected button=\(remoteButton?.rawValue ?? "unknown") signature=\(signature) keycode=\(keyCode.map(String.init) ?? "hid-only")")
        fflush(stdout)
        refreshMenu()
    }

    private func toggleBridge() -> Bool {
        bridgeEnabled.toggle()
        spotlightSuppressor?.setBridgeEnabled(bridgeEnabled)
        if !bridgeEnabled, streaming { setAudio(enabled: false) }
        refreshMenu()
        return bridgeEnabled
    }

    private func changeVoiceMode(_ mode: VoiceInputMode) throws {
        guard !streaming else { throw ProbeError.modeChangeWhileStreaming }
        voiceInputTrigger?.cancel()
        voiceInputTrigger = try VoiceInputTrigger(mode: mode)
        UserDefaults.standard.set(mode.rawValue, forKey: "voiceInputMode")
    }

    private func loadReturnMappings() {
        if let data = UserDefaults.standard.data(forKey: "remoteButtonMappings"),
           let decoded = try? JSONDecoder().decode([RemoteButtonMapping].self, from: data) {
            let filtered = decoded.filter { RemoteButtonKey.resolve(signature: $0.signature) != .microphone }
            buttonMappings = filtered
            if filtered.count != decoded.count,
               let cleanedData = try? JSONEncoder().encode(filtered) {
                UserDefaults.standard.set(cleanedData, forKey: "remoteButtonMappings")
            }
        }
    }

    private func beginButtonLearning(action: RemoteButtonAction) {
        learningAction = true
        pendingLearningAction = action
        spotlightSuppressor?.beginButtonLearning(action: action) { [weak self] signature, keyCode, action in
            guard let self else { return }
            self.finishButtonLearning(signature: signature, keyCode: keyCode, action: action)
        }
        refreshMenu()
    }

    private func finishButtonLearning(signature: String, keyCode: UInt16?, action: RemoteButtonAction) {
        guard RemoteButtonKey.resolve(signature: signature) != .microphone else {
            cancelButtonLearning()
            return
        }
        learningAction = false
        pendingLearningAction = nil
        spotlightSuppressor?.cancelReturnButtonLearning()
        buttonMappings.removeAll { mapping in
            mapping.signature == signature || (keyCode != nil && mapping.keyCode == keyCode)
        }
        buttonMappings.append(RemoteButtonMapping(signature: signature, keyCode: keyCode, action: action))
        if let data = try? JSONEncoder().encode(buttonMappings) {
            UserDefaults.standard.set(data, forKey: "remoteButtonMappings")
        }
        spotlightSuppressor?.setMappings(buttonMappings)
        if keyCode == nil {
            hidExecutionTimes[signature] = Date().timeIntervalSince1970
        }
        refreshMenu()
        print("remote_button_mapped signature=\(signature) keycode=\(keyCode.map(String.init) ?? "hid-only") action=\(action)")
    }

    private func clearButtonMappings() {
        learningAction = false
        pendingLearningAction = nil
        buttonMappings.removeAll()
        spotlightSuppressor?.cancelReturnButtonLearning()
        spotlightSuppressor?.setMappings([])
        UserDefaults.standard.removeObject(forKey: "remoteButtonMappings")
        refreshMenu()
    }

    private func removeButtonMapping(at index: Int) {
        guard buttonMappings.indices.contains(index) else { return }
        buttonMappings.remove(at: index)
        if let data = try? JSONEncoder().encode(buttonMappings) {
            UserDefaults.standard.set(data, forKey: "remoteButtonMappings")
        }
        spotlightSuppressor?.setMappings(buttonMappings)
        refreshMenu()
    }

    private func cancelButtonLearning() {
        learningAction = false
        pendingLearningAction = nil
        spotlightSuppressor?.cancelReturnButtonLearning()
        refreshMenu()
    }

    private func stop() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
        if streaming { setAudio(enabled: false) }
        voiceInputTrigger?.cancel()
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case openFailed(IOReturn)
    case missingOutputPath
    case missingVoiceMode
    case modeChangeWhileStreaming

    var description: String {
        switch self {
        case .openFailed(let code):
            return "Unable to open IOHIDManager (IOReturn \(code)). Grant Input Monitoring permission to the terminal or built app."
        case .missingOutputPath:
            return "--record-wav requires an output .wav path"
        case .missingVoiceMode:
            return "--voice-key requires none, fn-hold, fn-toggle, left-option-hold, or right-option-hold"
        case .modeChangeWhileStreaming:
            return "Release the remote microphone button before changing the voice key"
        }
    }
}

do {
    try MainActor.assumeIsolated { try Probe().run() }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
