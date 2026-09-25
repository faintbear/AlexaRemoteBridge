import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

private struct EventRecord {
    let time: TimeInterval
    let type: UInt32
    let keycode: Int64
    let subtype: Int
    let data1: Int

    var summary: String {
        "event type=\(type) keycode=\(keycode) subtype=\(subtype) data1=0x\(String(data1, radix: 16))"
    }
}

private final class EventProbe: @unchecked Sendable {
    private let suppress = CommandLine.arguments.contains("--suppress")
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var tap: CFMachPort?
    private var recent: [EventRecord] = []
    private var windowUntil: TimeInterval = 0

    deinit { buffer.deallocate() }

    func run() throws {
        buffer.initialize(repeating: 0, count: 512)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x0171,
            kIOHIDProductIDKey as String: 0x041E,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<EventProbe>.fromOpaque(context).takeUnretainedValue().matched(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { throw ProbeError.hid(openResult) }

        let systemDefined = CGEventType(rawValue: 14)!
        let mask = (CGEventMask(1) << systemDefined.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: suppress ? .defaultTap : .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            if Unmanaged<EventProbe>.fromOpaque(context).takeUnretainedValue().observed(type, event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else { throw ProbeError.tap }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("event_probe_started scope=AR_mic_300ms mode=\(suppress ? "suppress_spotlight" : "listen_only")")
        fflush(stdout)
        RunLoop.current.run()
    }

    private func matched(_ device: IOHIDDevice) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            Unmanaged<EventProbe>.fromOpaque(context).takeUnretainedValue()
                .received(reportID: reportID, bytes: report, length: length)
        }, context)
        print("remote_matched")
        fflush(stdout)
    }

    private func received(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard reportID == 2, length >= 3, bytes[1] == 0x21, bytes[2] == 0x02 else { return }
        let now = Date().timeIntervalSince1970
        print("mic_pressed")
        for record in recent where now - record.time <= 0.3 {
            print("before_mic \(record.summary)")
        }
        windowUntil = now + 0.3
        fflush(stdout)
    }

    private func observed(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let now = Date().timeIntervalSince1970
        let nsEvent = type.rawValue == 14 ? NSEvent(cgEvent: event) : nil
        let record = EventRecord(time: now, type: type.rawValue,
                                 keycode: event.getIntegerValueField(.keyboardEventKeycode),
                                 subtype: Int(nsEvent?.subtype.rawValue ?? 0),
                                 data1: nsEvent?.data1 ?? 0)
        recent.append(record)
        recent.removeAll { now - $0.time > 0.3 }
        if now <= windowUntil {
            print("after_mic \(record.summary)")
            fflush(stdout)
        }
        if suppress, now <= windowUntil, (type == .keyDown || type == .keyUp), record.keycode == 177 {
            print("suppressed_spotlight_key")
            fflush(stdout)
            return true
        }
        return false
    }
}

private enum ProbeError: Error {
    case hid(IOReturn)
    case tap
}

do { try EventProbe().run() }
catch {
    fputs("event_probe_error: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
