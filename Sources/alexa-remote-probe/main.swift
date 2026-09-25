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

private final class Probe {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]

    deinit {
        for buffer in buffers.values {
            buffer.deallocate()
        }
    }

    func run() throws {
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
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw ProbeError.openFailed(result)
        }

        print("\(timestamp()) probe_started vid=0x0171 pid=0x041E mode=read_only")
        print("Press ordinary buttons, then hold the Alexa button and speak. Press Control-C to stop.")
        RunLoop.current.run()
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard buffers[device] == nil else { return }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maximumReportLength)
        buffer.initialize(repeating: 0, count: maximumReportLength)
        buffers[device] = buffer

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
        if let buffer = buffers.removeValue(forKey: device) {
            buffer.deallocate()
        }
        print("\(timestamp()) device_removed")
    }

    private func received(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let safeLength = max(0, Int(length))
        let prefix = hexPrefix(UnsafePointer(bytes), length: safeLength)
        print("\(timestamp()) input report=0x\(String(format: "%02X", reportID)) length=\(safeLength) prefix=\(prefix)")
        fflush(stdout)
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case openFailed(IOReturn)

    var description: String {
        switch self {
        case .openFailed(let code):
            return "Unable to open IOHIDManager (IOReturn \(code)). Grant Input Monitoring permission to the terminal or built app."
        }
    }
}

do {
    try Probe().run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
