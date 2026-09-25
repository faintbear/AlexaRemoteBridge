import AppKit
import Foundation

/// A small everyday entry point while the full button-mapping window is built.
@MainActor final class MenuBarApp: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let onToggle: () -> Bool
    private let onModeChange: (VoiceInputMode) throws -> Void
    private let onLearnReturn: () -> Void
    private let onClearReturn: () -> Void
    private let onQuit: () -> Void
    private var connected = false
    private var speaking = false
    private var enabled = true
    private var learningReturn = false
    private var hasReturnMapping = false
    private var canLearnReturn = false
    private var mode: VoiceInputMode
    private var errorMessage: String?
    private var permissionNotice: String?

    init(mode: VoiceInputMode,
         onToggle: @escaping () -> Bool,
         onModeChange: @escaping (VoiceInputMode) throws -> Void,
         onLearnReturn: @escaping () -> Void,
         onClearReturn: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.mode = mode
        self.onToggle = onToggle
        self.onModeChange = onModeChange
        self.onLearnReturn = onLearnReturn
        self.onClearReturn = onClearReturn
        self.onQuit = onQuit
        super.init()
        statusItem.menu = menu
        refresh()
    }

    func update(connected: Bool, speaking: Bool, enabled: Bool,
                learningReturn: Bool, hasReturnMapping: Bool, canLearnReturn: Bool,
                permissionNotice: String?) {
        self.connected = connected
        self.speaking = speaking
        self.enabled = enabled
        self.learningReturn = learningReturn
        self.hasReturnMapping = hasReturnMapping
        self.canLearnReturn = canLearnReturn
        self.permissionNotice = permissionNotice
        refresh()
    }

    private func refresh() {
        statusItem.button?.title = speaking ? "AR ●" : "AR"
        statusItem.button?.toolTip = connected ? "Alexa 遥控器已连接" : "Alexa 遥控器未连接"
        menu.removeAllItems()
        addStatus(connected ? "遥控器：已连接" : "遥控器：未连接")
        addStatus(speaking ? "麦克风：正在输入" : "麦克风：待机")
        addStatus("音频输出：BlackHole 2ch")
        addStatus(learningReturn ? "发送键：请按下想映射为 Return 的遥控器按键" :
                  (hasReturnMapping ? "发送键：已配置" : "发送键：尚未配置"))
        if let permissionNotice { addStatus(permissionNotice) }
        if let errorMessage { addStatus("提示：\(errorMessage)") }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: enabled ? "暂停桥接" : "开启桥接",
                                action: #selector(toggleBridge), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let modeItem = NSMenuItem(title: "语音输入触发键", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for (value, title) in [
            (VoiceInputMode.none, "不触发输入法"),
            (.fnHold, "Fn 长按"),
            (.fnToggle, "Fn 点按开／关"),
            (.leftOptionHold, "左 Option 长按"),
            (.rightOptionHold, "右 Option 长按"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.rawValue
            item.state = value == mode ? .on : .off
            modeMenu.addItem(item)
        }
        menu.setSubmenu(modeMenu, for: modeItem)
        menu.addItem(modeItem)
        let learn = NSMenuItem(title: "学习 Return 发送键…", action: #selector(learnReturn), keyEquivalent: "")
        learn.target = self
        learn.isEnabled = !learningReturn && canLearnReturn
        menu.addItem(learn)
        let clear = NSMenuItem(title: "清除 Return 映射", action: #selector(clearReturn), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = hasReturnMapping
        menu.addItem(clear)
        menu.addItem(.separator())
        addStatus("在语音输入法中选择 BlackHole 2ch")
        addStatus("语音键：按住说话，松开停止")
        menu.addItem(.separator())
        let inputSettings = NSMenuItem(title: "打开输入监控设置…", action: #selector(openInputMonitoring), keyEquivalent: "")
        inputSettings.target = self
        menu.addItem(inputSettings)
        let accessibilitySettings = NSMenuItem(title: "打开辅助功能设置…", action: #selector(openAccessibility), keyEquivalent: "")
        accessibilitySettings.target = self
        menu.addItem(accessibilitySettings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AlexaRemoteBridge", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addStatus(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func toggleBridge() {
        enabled = onToggle()
        errorMessage = nil
        refresh()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = VoiceInputMode(rawValue: raw) else { return }
        do {
            try onModeChange(selected)
            mode = selected
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        refresh()
    }

    @objc private func quitApp() {
        onQuit()
        NSApplication.shared.terminate(nil)
    }

    @objc private func learnReturn() {
        onLearnReturn()
        learningReturn = true
        refresh()
    }

    @objc private func clearReturn() {
        onClearReturn()
        hasReturnMapping = false
        refresh()
    }

    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
