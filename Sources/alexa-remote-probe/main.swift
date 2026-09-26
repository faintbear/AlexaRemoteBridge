import AppKit
import Foundation
import IOKit.hid

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
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
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
    private var bridgeEnabled = true
    private var learningReturn = false
    private var returnMappings: [UInt16: String] = [:]
    private var permissionNotice: String?
    private var audioFrames = 0
    private var safetyTimer: Timer?

    isolated deinit {
        for buffer in buffers.values {
            buffer.deallocate()
        }
    }

    func run() throws {
        if let index = CommandLine.arguments.firstIndex(of: "--record-wav") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw ProbeError.missingOutputPath
            }
            recorder = try OpusRecorder(path: CommandLine.arguments[index + 1])
        }
        if liveMode {
            liveOutput = try LiveAudioOutput(deviceName: "BlackHole 2ch")
            if recorder == nil { recorder = try OpusRecorder(path: nil) }
            let voiceMode = try Self.selectedVoiceMode()
            voiceInputTrigger = try VoiceInputTrigger(mode: voiceMode)
            if appMode && !AXIsProcessTrusted() {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            do {
                spotlightSuppressor = try SpotlightSuppressor()
                loadReturnMappings()
                print("spotlight_suppression_ready scope=AR_mic_hold_plus_300ms")
            } catch {
                permissionNotice = "请在辅助功能设置中授权 AlexaRemoteBridge"
                fputs("warning: Spotlight suppression needs Accessibility permission; live audio will still run\n", stderr)
            }
            if !AXIsProcessTrusted() {
                permissionNotice = "左 Option 触发和按键映射需要辅助功能授权"
            }
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
        if result != kIOReturnSuccess, appMode {
            permissionNotice = "请在输入监控设置中授权 AlexaRemoteBridge，然后重启应用"
        } else if result != kIOReturnSuccess {
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
        if appMode {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            menuBar = MenuBarApp(mode: voiceInputTrigger?.mode ?? .none,
                                 onToggle: { [weak self] in self?.toggleBridge() ?? false },
                                 onModeChange: { [weak self] mode in try self?.changeVoiceMode(mode) },
                                 onLearnReturn: { [weak self] in self?.beginReturnLearning() },
                                 onClearReturn: { [weak self] in self?.clearReturnMapping() },
                                 onQuit: { [weak self] in self?.stop() })
            refreshMenu()
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
        refreshMenu()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        if remote == device {
            if streaming { setAudio(enabled: false) }
            remote = nil
            streaming = false
            micButtonDown = false
            spotlightSuppressor?.noteMicRelease()
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
            if hasButtonPayload, !(reportID == 2 && usage == 0x0221) {
                let signature = String(format: "%02X:%02X:%02X", reportID, bytes[1], bytes[2])
                spotlightSuppressor?.noteHardwareButton(signature: signature)
            }
        }
        if bridgeEnabled && (audioTest || recorder != nil), reportID == 2, safeLength >= 3 {
            let usage = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            if usage == 0x0221, !micButtonDown {
                micButtonDown = true
                print("\(timestamp()) remote_mic_down suppressor_ready=\(spotlightSuppressor != nil)")
                fflush(stdout)
                spotlightSuppressor?.noteMicPress()
                if !streaming { setAudio(enabled: true) }
            }
            if usage == 0, micButtonDown {
                micButtonDown = false
                spotlightSuppressor?.noteMicRelease()
                if streaming { setAudio(enabled: false) }
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
        let report: [UInt8] = [0xF2, enabled ? 0x01 : 0x00]
        let result = report.withUnsafeBufferPointer { pointer in
            IOHIDDeviceSetReport(remote, kIOHIDReportTypeOutput, 0xF2, pointer.baseAddress!, report.count)
        }
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
                    self.spotlightSuppressor?.noteMicRelease()
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
                        learningReturn: learningReturn, hasReturnMapping: !returnMappings.isEmpty,
                        canLearnReturn: spotlightSuppressor != nil,
                        permissionNotice: permissionNotice)
    }

    private func toggleBridge() -> Bool {
        bridgeEnabled.toggle()
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
        let saved = UserDefaults.standard.dictionary(forKey: "returnButtonMappings") as? [String: NSNumber] ?? [:]
        returnMappings.removeAll()
        for (signature, code) in saved {
            guard let value = UInt16(exactly: code.intValue) else { continue }
            returnMappings[value] = signature
        }
        spotlightSuppressor?.setReturnMappings(returnMappings)
    }

    private func beginReturnLearning() {
        learningReturn = true
        spotlightSuppressor?.beginReturnButtonLearning { [weak self] signature, keyCode in
            guard let self else { return }
            self.learningReturn = false
            self.returnMappings.removeAll()
            self.returnMappings[keyCode] = signature
            let saved = Dictionary(uniqueKeysWithValues: self.returnMappings.map { ($1, NSNumber(value: $0)) })
            UserDefaults.standard.set(saved, forKey: "returnButtonMappings")
            self.spotlightSuppressor?.setReturnMappings(self.returnMappings)
            self.refreshMenu()
            print("return_button_mapped signature=\(signature) keycode=\(keyCode)")
        }
        refreshMenu()
    }

    private func clearReturnMapping() {
        learningReturn = false
        returnMappings.removeAll()
        spotlightSuppressor?.cancelReturnButtonLearning()
        spotlightSuppressor?.setReturnMappings([:])
        UserDefaults.standard.removeObject(forKey: "returnButtonMappings")
        refreshMenu()
    }

    private func stop() {
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
