import AppKit
import Carbon
import Foundation

enum InputSourceStatus: Equatable {
    case doubao(identifier: String, name: String)
    case other(identifier: String, name: String)
    case unavailable

    var isDoubao: Bool {
        if case .doubao = self { return true }
        return false
    }

    var identifier: String? {
        switch self {
        case .doubao(let identifier, _), .other(let identifier, _):
            return identifier
        case .unavailable:
            return nil
        }
    }

    var name: String? {
        switch self {
        case .doubao(_, let name), .other(_, let name):
            return name.isEmpty ? nil : name
        case .unavailable:
            return nil
        }
    }

    var menuNotice: String? {
        guard case .other(_, let name) = self else { return nil }
        if name.isEmpty {
            return "当前输入法不是豆包输入法，请切换后再使用"
        }
        return "当前输入法：\(name)，请切换到豆包输入法"
    }
}

enum InputSourceMonitor {
    private static let doubaoIdentifierPrefix = "com.bytedance.inputmethod.doubaoime"
    private static let doubaoLocalizedNames: Set<String> = ["豆包输入法", "Doubao Input Method"]

    static func current() -> InputSourceStatus {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return .unavailable
        }
        let identifier = stringProperty(source, key: kTISPropertyInputSourceID) ?? ""
        let name = stringProperty(source, key: kTISPropertyLocalizedName) ?? ""
        guard !identifier.isEmpty || !name.isEmpty else { return .unavailable }

        if identifier.hasPrefix(doubaoIdentifierPrefix) || doubaoLocalizedNames.contains(name) {
            return .doubao(identifier: identifier, name: name)
        }
        return .other(identifier: identifier, name: name)
    }

    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.keyboard?InputSources",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        ]
        for string in urls {
            guard let url = URL(string: string), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    private static func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? String
    }
}
