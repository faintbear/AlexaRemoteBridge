import Foundation

enum RemoteButtonAction: Codable, Equatable {
    case sendReturn
    case launchApp(path: String)
}

struct RemoteButtonMapping: Codable, Equatable {
    let signature: String
    let keyCode: UInt16
    let action: RemoteButtonAction
}

struct DetectedRemoteButton: Equatable, Identifiable {
    let signature: String
    let keyCode: UInt16?
    let remoteButton: RemoteButtonKey?
    let detectedAt: Date

    var id: String { "\(signature)-\(keyCode.map(String.init) ?? "hid")" }
}

enum RemoteButtonKey: String, Codable, Equatable {
    case power, microphone
    case up, left, select, right, down
    case back, home, menu
    case rewind, playPause, fastForward
    case mute, volumeUp, tv, volumeDown
    case prime, netflix, disney, hulu

    private static let observedSignatures: [String: RemoteButtonKey] = [
        "01:66:00": .power,
        "02:21:02": .microphone,
        "01:52:00": .up,
        "01:50:00": .left,
        "01:58:00": .select,
        "01:4F:00": .right,
        "01:51:00": .down,
        "01:F1:00": .back,
        "02:23:02": .home,
        "02:40:00": .menu,
        "02:B4:00": .rewind,
        "02:CD:00": .playPause,
        "02:B3:00": .fastForward,
        "02:E2:00": .mute,
        "02:E9:00": .volumeUp,
        "02:8D:00": .tv,
        "02:EA:00": .volumeDown,
        "EF:A1:00": .prime,
        "EF:A2:00": .netflix,
        "EF:A3:00": .disney,
        "EF:A4:00": .hulu,
    ]

    static func resolve(reportID: UInt32, usage: UInt16) -> RemoteButtonKey? {
        let signature = String(format: "%02X:%02X:%02X", reportID, usage & 0x00FF, usage >> 8)
        return observedSignatures[signature]
    }

    static func resolve(signature: String) -> RemoteButtonKey? {
        observedSignatures[signature.uppercased()]
    }
}
