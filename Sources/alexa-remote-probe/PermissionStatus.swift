import Foundation

enum PermissionStatus: Equatable, Sendable {
    case notGranted
    case needsRestart
    case granted

    var isGranted: Bool { self == .granted }
}
