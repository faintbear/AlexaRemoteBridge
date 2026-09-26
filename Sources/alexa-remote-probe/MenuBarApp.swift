import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum AppLanguage {
    enum Choice: String, CaseIterable, Identifiable {
        case system
        case chinese
        case english

        var id: String { rawValue }

        var menuTitle: String {
            switch self {
            case .system: return AppLanguage.isChinese ? "跟随系统" : "System Default"
            case .chinese: return "简体中文"
            case .english: return "English"
            }
        }
    }

    private static let preferenceKey = "interfaceLanguage"

    static var choice: Choice {
        Choice(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
    }

    static var isChinese: Bool {
        switch choice {
        case .system: return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? true
        case .chinese: return true
        case .english: return false
        }
    }

    static func setChoice(_ choice: Choice) {
        UserDefaults.standard.set(choice.rawValue, forKey: preferenceKey)
    }

    static func text(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }
}

private func localizedRuntimeMessage(_ message: String) -> String {
    switch message {
    case "请在辅助功能设置中授权 AlexaRemoteBridge":
        return AppLanguage.text(message, "Grant AlexaRemoteBridge permission in Accessibility settings")
    case "左 Option 触发和按键映射需要辅助功能授权":
        return AppLanguage.text(message, "Accessibility permission is required for Left Option triggering and button mapping")
    case "请在输入监控设置中授权 AlexaRemoteBridge，然后重启应用":
        return AppLanguage.text(message, "Grant AlexaRemoteBridge permission in Input Monitoring settings, then restart the app")
    case "输入监控授权后请完全退出并重新打开 App":
        return AppLanguage.text(message, "After granting Input Monitoring, fully quit and reopen the app")
    case "需要辅助功能授权以执行按键映射和聚焦输入框":
        return AppLanguage.text(message, "Accessibility permission is required for button mapping and input focus")
    default:
        if message.hasPrefix("音频输出初始化失败：") {
            let detail = String(message.dropFirst("音频输出初始化失败：".count))
            return AppLanguage.text("音频输出初始化失败：\(detail)", "Audio output initialization failed: \(detail)")
        }
        return message
    }
}

/// A small everyday entry point while the full button-mapping window is built.
@MainActor final class MenuBarApp: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let onToggle: () -> Bool
    private let onModeChange: (VoiceInputMode) throws -> Void
    private let onLearnAction: (RemoteButtonAction) -> Void
    private let onChooseApp: (String) -> Void
    private let onClearMappings: () -> Void
    private let onRemoveMapping: (Int) -> Void
    private let onCancelLearning: () -> Void
    private let onRefreshPermissions: () -> Void
    private let onQuit: () -> Void
    private var connected = false
    private var speaking = false
    private var enabled = true
    private var learningAction = false
    private var mappingCount = 0
    private var canLearnReturn = false
    private var mode: VoiceInputMode
    private var errorMessage: String?
    private var permissionNotice: String?
    private var mappingWindow: ButtonMappingWindow?
    private var mappings: [RemoteButtonMapping] = []
    private var detectedButtons: [DetectedRemoteButton] = []
    private var isRemoteConnected = false
    private var inputMonitoringGranted = false
    private var accessibilityGranted = false

    init(mode: VoiceInputMode,
         onToggle: @escaping () -> Bool,
         onModeChange: @escaping (VoiceInputMode) throws -> Void,
         onLearnAction: @escaping (RemoteButtonAction) -> Void,
         onChooseApp: @escaping (String) -> Void,
         onClearMappings: @escaping () -> Void,
         onRemoveMapping: @escaping (Int) -> Void,
         onCancelLearning: @escaping () -> Void,
         onRefreshPermissions: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.mode = mode
        self.onToggle = onToggle
        self.onModeChange = onModeChange
        self.onLearnAction = onLearnAction
        self.onChooseApp = onChooseApp
        self.onClearMappings = onClearMappings
        self.onRemoveMapping = onRemoveMapping
        self.onCancelLearning = onCancelLearning
        self.onRefreshPermissions = onRefreshPermissions
        self.onQuit = onQuit
        super.init()
        statusItem.menu = menu
        refresh()
    }

    func update(connected: Bool, speaking: Bool, enabled: Bool,
                learningAction: Bool, mappingCount: Int, canLearnReturn: Bool,
                permissionNotice: String?, mappings: [RemoteButtonMapping],
                detectedButtons: [DetectedRemoteButton],
                inputMonitoringGranted: Bool, accessibilityGranted: Bool) {
        self.connected = connected
        self.speaking = speaking
        self.enabled = enabled
        self.learningAction = learningAction
        self.mappingCount = mappingCount
        self.canLearnReturn = canLearnReturn
        self.permissionNotice = permissionNotice
        self.mappings = mappings
        self.detectedButtons = detectedButtons
        self.isRemoteConnected = connected
        self.inputMonitoringGranted = inputMonitoringGranted
        self.accessibilityGranted = accessibilityGranted
        mappingWindow?.update(mappings: mappings, learning: learningAction,
                              connected: connected, detectedButtons: detectedButtons,
                              inputMonitoringGranted: inputMonitoringGranted,
                              accessibilityGranted: accessibilityGranted)
        refresh()
    }

    private func refresh() {
        statusItem.button?.title = speaking ? "AR ●" : "AR"
        statusItem.button?.toolTip = connected ? AppLanguage.text("Alexa 遥控器已连接", "Alexa remote connected") : AppLanguage.text("Alexa 遥控器未连接", "Alexa remote disconnected")
        menu.removeAllItems()
        addStatus(connected ? AppLanguage.text("遥控器：已连接", "Remote: Connected") : AppLanguage.text("遥控器：未连接", "Remote: Disconnected"))
        addStatus(speaking ? AppLanguage.text("麦克风：正在输入", "Microphone: Streaming") : AppLanguage.text("麦克风：待机", "Microphone: Idle"))
        addStatus(AppLanguage.text("音频输出：BlackHole 2ch", "Audio Output: BlackHole 2ch"))
        addStatus(learningAction ? AppLanguage.text("按键学习：请按要绑定动作的遥控器按键", "Learning: Press a remote button to bind") :
                  AppLanguage.text("按键映射：已配置 \(mappingCount) 个", "Button mappings: \(mappingCount) configured"))
        if let permissionNotice { addStatus(localizedRuntimeMessage(permissionNotice)) }
        if let errorMessage { addStatus("\(AppLanguage.text("提示", "Notice")): \(errorMessage)") }
        menu.addItem(.separator())

        let openMain = NSMenuItem(title: AppLanguage.text("打开主界面", "Open Main Window"), action: #selector(openMainInterface), keyEquivalent: "")
        openMain.target = self
        menu.addItem(openMain)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: enabled ? AppLanguage.text("暂停桥接", "Pause Bridge") : AppLanguage.text("开启桥接", "Resume Bridge"),
                                action: #selector(toggleBridge), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let modeItem = NSMenuItem(title: AppLanguage.text("语音输入触发键", "Voice Input Trigger"), action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for (value, title) in [
            (VoiceInputMode.none, AppLanguage.text("不触发输入法", "No Input Trigger")),
            (.fnHold, AppLanguage.text("Fn 长按", "Hold Fn")),
            (.fnToggle, AppLanguage.text("Fn 点按开／关", "Tap Fn to Toggle")),
            (.leftOptionHold, AppLanguage.text("左 Option 长按", "Hold Left Option")),
            (.rightOptionHold, AppLanguage.text("右 Option 长按", "Hold Right Option")),
        ] {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.rawValue
            item.state = value == mode ? .on : .off
            modeMenu.addItem(item)
        }
        menu.setSubmenu(modeMenu, for: modeItem)
        menu.addItem(modeItem)
        let languageItem = NSMenuItem(title: AppLanguage.text("界面语言", "Interface Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for choice in AppLanguage.Choice.allCases {
            let item = NSMenuItem(title: choice.menuTitle, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == AppLanguage.choice ? .on : .off
            languageMenu.addItem(item)
        }
        menu.setSubmenu(languageMenu, for: languageItem)
        menu.addItem(languageItem)
        let launch = NSMenuItem(title: AppLanguage.text("学习按键打开 App 并聚焦输入框…", "Map Button to Open App and Focus Input…"), action: #selector(chooseApp), keyEquivalent: "")
        launch.target = self
        launch.isEnabled = !learningAction && canLearnReturn
        menu.addItem(launch)
        let settings = NSMenuItem(title: AppLanguage.text("按键映射设置…", "Button Mapping Settings…"), action: #selector(openMappingSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let clear = NSMenuItem(title: AppLanguage.text("清除按键映射", "Clear Button Mappings"), action: #selector(clearMappings), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = mappingCount > 0
        menu.addItem(clear)
        menu.addItem(.separator())
        addStatus(AppLanguage.text("在语音输入法中选择 BlackHole 2ch", "Select BlackHole 2ch in your voice input app"))
        addStatus(AppLanguage.text("语音键：按住说话，松开停止", "Voice button: hold to speak, release to stop"))
        menu.addItem(.separator())
        let inputSettings = NSMenuItem(title: AppLanguage.text("打开输入监控设置…", "Open Input Monitoring Settings…"), action: #selector(openInputMonitoring), keyEquivalent: "")
        inputSettings.target = self
        menu.addItem(inputSettings)
        let accessibilitySettings = NSMenuItem(title: AppLanguage.text("打开辅助功能设置…", "Open Accessibility Settings…"), action: #selector(openAccessibility), keyEquivalent: "")
        accessibilitySettings.target = self
        menu.addItem(accessibilitySettings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: AppLanguage.text("退出 AlexaRemoteBridge", "Quit AlexaRemoteBridge"), action: #selector(quitApp), keyEquivalent: "q")
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

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = AppLanguage.Choice(rawValue: raw) else { return }
        AppLanguage.setChoice(choice)
        mappingWindow?.setLanguage(choice)
        refresh()
    }

    @objc private func quitApp() {
        onQuit()
        NSApplication.shared.terminate(nil)
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.text("选择按键要打开并聚焦输入框的 App", "Choose the app to open and focus with this button")
        panel.prompt = AppLanguage.text("选择 App", "Choose App")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path, let self else { return }
            self.onChooseApp(path)
            self.learningAction = true
            self.refresh()
        }
    }

    @objc private func clearMappings() {
        onClearMappings()
        mappingCount = 0
        refresh()
    }

    @objc private func openMappingSettings() {
        if mappingWindow == nil {
            mappingWindow = ButtonMappingWindow(
                onChooseApp: onChooseApp,
                onLearnReturn: { [weak self] in self?.onLearnAction(.sendReturn) },
                onRemoveMapping: onRemoveMapping,
                onCancelLearning: onCancelLearning,
                onRefreshPermissions: onRefreshPermissions,
                onLanguageChange: { [weak self] in self?.refresh() }
            )
        }
        mappingWindow?.update(mappings: mappings, learning: learningAction,
                              connected: isRemoteConnected, detectedButtons: detectedButtons,
                              inputMonitoringGranted: inputMonitoringGranted,
                              accessibilityGranted: accessibilityGranted)
        mappingWindow?.showWindow(nil)
        mappingWindow?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func openMainInterface() {
        openMappingSettings()
    }

    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

@MainActor private final class ButtonMappingWindow: NSWindowController {
    init(onChooseApp: @escaping (String) -> Void,
         onLearnReturn: @escaping () -> Void,
         onRemoveMapping: @escaping (Int) -> Void,
         onCancelLearning: @escaping () -> Void,
         onRefreshPermissions: @escaping () -> Void,
         onLanguageChange: @escaping () -> Void) {
        let model = MappingDashboardModel(onChooseApp: onChooseApp,
                                          onLearnReturn: onLearnReturn,
                                          onRemoveMapping: onRemoveMapping,
                                          onCancelLearning: onCancelLearning,
                                          onRefreshPermissions: onRefreshPermissions,
                                          onLanguageChange: onLanguageChange)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = AppLanguage.text("AlexaRemoteBridge", "AlexaRemoteBridge")
        window.center()
        self.model = model
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: MappingDashboard(model: model))
    }

    required init?(coder: NSCoder) { nil }

    private let model: MappingDashboardModel

    func update(mappings: [RemoteButtonMapping], learning: Bool,
                connected: Bool, detectedButtons: [DetectedRemoteButton],
                inputMonitoringGranted: Bool, accessibilityGranted: Bool) {
        model.update(mappings: mappings, learning: learning,
                     connected: connected, detectedButtons: detectedButtons,
                     inputMonitoringGranted: inputMonitoringGranted,
                     accessibilityGranted: accessibilityGranted)
    }

    func setLanguage(_ choice: AppLanguage.Choice) {
        model.setLanguage(choice)
    }
}

@MainActor private final class MappingDashboardModel: ObservableObject {
    @Published private(set) var mappings: [RemoteButtonMapping] = []
    @Published private(set) var learning = false
    @Published private(set) var connected = false
    @Published private(set) var detectedButtons: [DetectedRemoteButton] = []
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published var languageSelection = AppLanguage.choice.rawValue {
        didSet {
            guard let choice = AppLanguage.Choice(rawValue: languageSelection) else { return }
            AppLanguage.setChoice(choice)
            onLanguageChange()
        }
    }
    private let onChooseApp: (String) -> Void
    private let onLearnReturn: () -> Void
    private let onRemoveMapping: (Int) -> Void
    private let onCancelLearning: () -> Void
    private let onRefreshPermissions: () -> Void
    private let onLanguageChange: () -> Void

    init(onChooseApp: @escaping (String) -> Void,
         onLearnReturn: @escaping () -> Void,
         onRemoveMapping: @escaping (Int) -> Void,
         onCancelLearning: @escaping () -> Void,
         onRefreshPermissions: @escaping () -> Void,
         onLanguageChange: @escaping () -> Void) {
        self.onChooseApp = onChooseApp
        self.onLearnReturn = onLearnReturn
        self.onRemoveMapping = onRemoveMapping
        self.onCancelLearning = onCancelLearning
        self.onRefreshPermissions = onRefreshPermissions
        self.onLanguageChange = onLanguageChange
    }

    func update(mappings: [RemoteButtonMapping], learning: Bool,
                connected: Bool, detectedButtons: [DetectedRemoteButton],
                inputMonitoringGranted: Bool, accessibilityGranted: Bool) {
        self.mappings = mappings
        self.learning = learning
        self.connected = connected
        self.detectedButtons = detectedButtons
        self.inputMonitoringGranted = inputMonitoringGranted
        self.accessibilityGranted = accessibilityGranted
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.text("选择要绑定的 App", "Choose an app to bind")
        panel.prompt = AppLanguage.text("下一步：按遥控器键", "Next: press a remote button")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] result in
            guard result == .OK, let path = panel.url?.path else { return }
            self?.onChooseApp(path)
        }
    }

    func learnReturn() { onLearnReturn() }
    func removeMapping(at index: Int) { onRemoveMapping(index) }
    func cancelLearning() { onCancelLearning() }
    func refreshPermissions() { onRefreshPermissions() }
    func setLanguage(_ choice: AppLanguage.Choice) { languageSelection = choice.rawValue }
    func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

@MainActor private struct MappingDashboard: View {
    @ObservedObject var model: MappingDashboardModel
    private let blue = Color(red: 0.02, green: 0.62, blue: 0.86)

    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            RemoteIllustration()
                .frame(width: 205, height: 540)
                .frame(width: 240)
                .frame(maxHeight: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    statusPill(AppLanguage.text("遥控器", "Remote"), value: model.connected ? AppLanguage.text("已连接 · 按任意普通键检测", "Connected · Press any regular button to detect") : AppLanguage.text("未连接", "Disconnected"), systemImage: "dot.radiowaves.left.and.right")
                    statusPill(AppLanguage.text("映射状态", "Mapping"), value: model.learning ? AppLanguage.text("正在学习…", "Learning…") : AppLanguage.text("已保存 \(model.mappings.count) 个", "\(model.mappings.count) saved"), systemImage: "checkmark.circle")
                    Spacer()
                    Picker(AppLanguage.text("界面语言", "Language"), selection: $model.languageSelection) {
                        ForEach(AppLanguage.Choice.allCases) { choice in
                            Text(choice.menuTitle).tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    Button { model.learning ? model.cancelLearning() : model.chooseApp() } label: {
                        Label(model.learning ? AppLanguage.text("取消学习", "Cancel Learning") : AppLanguage.text("添加按键", "Add Button"),
                              systemImage: model.learning ? "xmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(blue)
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(AppLanguage.text("权限设置", "Permissions")).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button(AppLanguage.text("刷新授权状态", "Refresh Status")) { model.refreshPermissions() }
                            .buttonStyle(.borderless)
                    }
                    HStack(spacing: 12) {
                        permissionCard(title: AppLanguage.text("输入监控", "Input Monitoring"),
                                       detail: AppLanguage.text("读取遥控器按键", "Read remote button presses"),
                                       granted: model.inputMonitoringGranted,
                                       actionTitle: AppLanguage.text("打开设置…", "Open Settings…"),
                                       action: model.openInputMonitoring)
                        permissionCard(title: AppLanguage.text("辅助功能", "Accessibility"),
                                       detail: AppLanguage.text("按键映射与聚焦输入框", "Button mapping and input focus"),
                                       granted: model.accessibilityGranted,
                                       actionTitle: AppLanguage.text("打开设置…", "Open Settings…"),
                                       action: model.openAccessibility)
                    }
                    Text(AppLanguage.text("在系统设置中允许 AlexaRemoteBridge；授权后点“刷新授权状态”。输入监控刚获准时若仍未连接，请完全退出并重新打开 App。", "Allow AlexaRemoteBridge in System Settings, then click “Refresh Status”. If the remote is still disconnected after granting Input Monitoring, fully quit and reopen the app."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text(AppLanguage.text("自定义操作", "Custom Actions")).font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                    Button(AppLanguage.text("添加 Return 映射", "Add Return Mapping")) { model.learnReturn() }
                        .buttonStyle(.bordered)
                        .disabled(model.learning)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLanguage.text("最近检测到的按键", "Recently Detected Buttons")).font(.system(size: 14)).foregroundStyle(.secondary)
                    if model.detectedButtons.isEmpty {
                        Text(model.connected ? AppLanguage.text("按一下遥控器上的任意普通按键，这里会显示检测结果。", "Press any regular remote button to see it detected here.") : AppLanguage.text("连接遥控器后即可检测按键。", "Connect the remote to detect its buttons."))
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(model.detectedButtons.prefix(4)) { button in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(button.keyCode.map(Self.keyName) ?? AppLanguage.text("HID 按键报告", "HID Button Report"))
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(button.keyCode.map { AppLanguage.text("键码 \($0) · ", "Keycode \($0) · ") } ?? "") + Text(button.signature)
                                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                }
                                .padding(9)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }
                }

                ScrollView {
                    if model.mappings.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.on.rectangle").font(.system(size: 30)).foregroundStyle(.secondary)
                            Text(AppLanguage.text("还没有按键映射", "No Button Mappings Yet")).font(.system(size: 16, weight: .semibold))
                            Text(AppLanguage.text("点击右上角“添加按键”，选择目标 App，再按一下遥控器按键完成绑定。", "Click “Add Button”, choose a target app, then press a remote button to finish mapping."))
                                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(Array(model.mappings.enumerated()), id: \.offset) { index, mapping in
                                mappingCard(mapping, index: index)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .frame(minWidth: 980, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statusPill(_ title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
    }

    private func permissionCard(title: String, detail: String, granted: Bool,
                                actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(granted ? AppLanguage.text("已授权 · \(detail)", "Granted · \(detail)") : AppLanguage.text("未授权 · \(detail)", "Not Granted · \(detail)"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action).buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
    }

    private func mappingCard(_ mapping: RemoteButtonMapping, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mapping.action.isApp ? "app.fill" : "return")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(mapping.action.isApp ? blue : Color(nsColor: .darkGray), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLanguage.text("遥控器键 · \(mapping.keyCode)", "Remote Button · \(mapping.keyCode)")).font(.system(size: 14, weight: .semibold))
                    Text(mapping.signature).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(AppLanguage.text("删除映射", "Remove Mapping"), role: .destructive) { model.removeMapping(at: index) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(6)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(15)
            Divider()
            HStack(spacing: 12) {
                Text(AppLanguage.text("短按", "Press")).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(actionName(mapping.action)).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(15)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 5, y: 2)
    }

    private func actionName(_ action: RemoteButtonAction) -> String {
        switch action {
        case .sendReturn: return AppLanguage.text("发送 Return", "Send Return")
        case .launchApp(let path): return AppLanguage.text("打开并聚焦输入框 · \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)", "Open and Focus Input · \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)")
        }
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return AppLanguage.text("空格", "Space")
        case 51: return "Delete"
        case 53: return "Escape"
        case 123: return AppLanguage.text("左方向键", "Left Arrow")
        case 124: return AppLanguage.text("右方向键", "Right Arrow")
        case 125: return AppLanguage.text("下方向键", "Down Arrow")
        case 126: return AppLanguage.text("上方向键", "Up Arrow")
        default: return AppLanguage.text("按键", "Button")
        }
    }
}

private extension RemoteButtonAction {
    var isApp: Bool {
        if case .launchApp = self { return true }
        return false
    }
}

private struct RemoteIllustration: View {
    private let button = Color(red: 0.13, green: 0.14, blue: 0.17)

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                keycap("power", size: 28)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 3)
            Circle()
                .fill(Color(red: 0.03, green: 0.64, blue: 0.88))
                .overlay(Image(systemName: "mic.fill").font(.system(size: 15)).foregroundStyle(.white))
                .frame(width: 38, height: 38)
                .padding(.bottom, 2)
            ZStack {
                Circle().fill(Color.black.opacity(0.68)).frame(width: 126, height: 126)
                Circle().fill(Color(red: 0.13, green: 0.14, blue: 0.17)).frame(width: 57, height: 57)
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8)).offset(y: -48)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8)).offset(y: 48)
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8)).offset(x: -48)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8)).offset(x: 48)
            }
            HStack(spacing: 13) {
                keycap("arrow.uturn.backward", size: 29)
                keycap("house.fill", size: 29)
                keycap("line.3.horizontal", size: 29)
            }
            HStack(spacing: 13) {
                keycap("backward.end.fill", size: 29)
                keycap("playpause.fill", size: 29)
                keycap("forward.end.fill", size: 29)
            }
            HStack(spacing: 13) {
                keycap("speaker.slash.fill", size: 29)
                volumeRocker
                keycap("tv", size: 29)
            }
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    capsuleKey("prime", color: Color(red: 0.04, green: 0.45, blue: 0.91))
                    capsuleKey("NETFLIX", color: Color(red: 0.91, green: 0.08, blue: 0.10))
                }
                HStack(spacing: 7) {
                    capsuleKey("Disney+", color: Color(red: 0.12, green: 0.19, blue: 0.75))
                    capsuleKey("hulu", color: Color(red: 0.02, green: 0.73, blue: 0.42), foreground: .black)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 15)
        .frame(width: 160, height: 520)
        .background(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 48))
        .overlay(RoundedRectangle(cornerRadius: 48).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private func keycap(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size).background(button, in: Circle())
    }

    private var volumeRocker: some View {
        VStack(spacing: 0) {
            Image(systemName: "plus").frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            Image(systemName: "minus").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 30, height: 55)
        .background(button, in: Capsule())
    }

    private func capsuleKey(_ title: String, color: Color, foreground: Color = .white) -> some View {
        Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(foreground)
            .frame(width: 49, height: 23).background(color.gradient, in: Capsule())
    }
}
