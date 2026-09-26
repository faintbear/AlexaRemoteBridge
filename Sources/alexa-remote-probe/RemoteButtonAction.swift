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
    let detectedAt: Date

    var id: String { "\(signature)-\(keyCode.map(String.init) ?? "hid")" }
}
