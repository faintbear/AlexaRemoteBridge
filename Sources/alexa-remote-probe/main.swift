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
private final class Probe: @unchecked Sendable {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private let seize = CommandLine.arguments.contains("--seize")
    private let audioTest = CommandLine.arguments.contains("--audio-test")
    private let liveMode = CommandLine.arguments.contains("--live")
    private var recorder: OpusRecorder?
    private var liveOutput: LiveAudioOutput?
    private var remote: IOHIDDevice?
    private var streaming = false
    private var audioFrames = 0
    private var safetyTimer: Timer?

    deinit {
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
        }
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: amazonVendorID,
            kIOHIDProductIDKey as String: alexaRemoteProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let options = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
        let result = IOHIDManagerOpen(manager, options)
        guard result == kIOReturnSuccess else {
            throw ProbeError.openFailed(result)
        }

        print("\(timestamp()) probe_started vid=0x0171 pid=0x041E mode=\(liveMode ? "live" : (recorder != nil ? "record_wav" : (audioTest ? "audio_test" : (seize ? "exclusive" : "read_only"))))")
        if seize { print("Other AR remote buttons are temporarily unavailable to macOS until this process stops.") }
        if audioTest || recorder != nil { print("The probe sends only HID output report F2=01 on mic press and F2=00 on release.") }
        if CommandLine.arguments.contains("--record-wav") { print("Audio is saved locally as 16 kHz mono PCM WAV after mic release.") }
        if liveMode { print("Audio is sent to BlackHole 2ch; select BlackHole 2ch as the microphone in the receiving app.") }
        print("Press ordinary buttons, then hold the Alexa button and speak. Press Control-C to stop.")
        RunLoop.current.run()
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
            Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
                .received(reportID: reportID, bytes: report, length: reportLength)
        }, context)

        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "unknown"
        print("\(timestamp()) device_matched product=\(product) transport=\(transport)")
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        if remote == device {
            remote = nil
            streaming = false
            safetyTimer?.invalidate()
        }
        if let buffer = buffers.removeValue(forKey: device) {
            buffer.deallocate()
        }
        print("\(timestamp()) device_removed")
    }

    private func received(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let safeLength = max(0, Int(length))
        if audioTest || recorder != nil, reportID == 2, safeLength >= 3 {
            let usage = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            if usage == 0x0221, !streaming { setAudio(enabled: true) }
            if usage == 0, streaming { setAudio(enabled: false) }
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
        guard result == kIOReturnSuccess else { return }
        streaming = enabled
        safetyTimer?.invalidate()
        if enabled {
            audioFrames = 0
            recorder?.start()
            liveOutput?.start()
            safetyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                guard let self, self.streaming else { return }
                print("\(timestamp()) safety_timeout")
                self.setAudio(enabled: false)
            }
        } else {
            liveOutput?.finish()
            do { try recorder?.finish() }
            catch { fputs("wav_save_failed error=\(error)\n", stderr) }
        }
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case openFailed(IOReturn)
    case missingOutputPath

    var description: String {
        switch self {
        case .openFailed(let code):
            return "Unable to open IOHIDManager (IOReturn \(code)). Grant Input Monitoring permission to the terminal or built app."
        case .missingOutputPath:
            return "--record-wav requires an output .wav path"
        }
    }
}

do {
    try Probe().run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
