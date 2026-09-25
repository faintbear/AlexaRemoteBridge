import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

final class LiveAudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
    private var pending: [Float] = []

    init(deviceName: String) throws {
        let deviceID = try Self.findOutputDevice(named: deviceName)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let unit = engine.outputNode.audioUnit else { throw LiveAudioError.outputUnitUnavailable }
        var selectedDevice = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &selectedDevice,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw LiveAudioError.deviceSelection(status) }
        try engine.start()
        player.play()
        print("live_output_ready device=\(deviceName)")
        fflush(stdout)
    }

    func start() {
        pending.removeAll(keepingCapacity: true)
        player.stop()
        player.play()
    }

    func append(_ samples: [Int16]) {
        pending.append(contentsOf: samples.map { Float($0) / 32_768.0 })
        while pending.count >= 1_600 {
            schedule(Array(pending.prefix(1_600)))
            pending.removeFirst(1_600)
        }
    }

    func finish() {
        if !pending.isEmpty {
            pending.append(contentsOf: repeatElement(0, count: max(0, 1_600 - pending.count)))
            schedule(pending)
            pending.removeAll(keepingCapacity: true)
        }
    }

    private func schedule(_ samples: [Float]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private static func findOutputDevice(named requestedName: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else {
            throw LiveAudioError.deviceEnumeration
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let enumerationStatus = devices.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       0, nil, &size, buffer.baseAddress!)
        }
        guard enumerationStatus == noErr else { throw LiveAudioError.deviceEnumeration }
        for device in devices {
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &name) { pointer in
                AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, pointer)
            }
            if status == noErr, (name as String) == requestedName { return device }
        }
        throw LiveAudioError.deviceNotFound(requestedName)
    }
}

private enum LiveAudioError: Error, CustomStringConvertible {
    case outputUnitUnavailable
    case deviceEnumeration
    case deviceSelection(OSStatus)
    case deviceNotFound(String)

    var description: String {
        switch self {
        case .outputUnitUnavailable: "CoreAudio output unit is unavailable"
        case .deviceEnumeration: "Could not enumerate CoreAudio devices"
        case .deviceSelection(let status): "Could not select output device (OSStatus \(status))"
        case .deviceNotFound(let name): "Audio device '\(name)' not found; install BlackHole 2ch and restart if needed"
        }
    }
}
