import AppKit
import ApplicationServices
import Foundation
import IOKit.hidsystem
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
    case "请在输入监控设置中授权 AlexaRemoteBridge":
        return AppLanguage.text(message, "Grant AlexaRemoteBridge permission in Input Monitoring settings")
    case "请在输入监控设置中授权 AlexaRemoteBridge，然后重启应用":
        return AppLanguage.text(message, "Grant AlexaRemoteBridge permission in Input Monitoring settings, then restart the app")
    case "输入监控授权后请完全退出并重新打开 App":
        return AppLanguage.text(message, "After granting Input Monitoring, fully quit and reopen the app")
    case "输入监控已授权但运行时尚未就绪，请完全退出并重新打开 App":
        return AppLanguage.text(message, "Input Monitoring is granted, but the runtime is not ready. Fully quit and reopen the app")
    case "需要辅助功能授权以执行按键映射和聚焦输入框":
        return AppLanguage.text(message, "Accessibility permission is required for button mapping and input focus")
    case "辅助功能已授权但运行时尚未就绪，请完全退出并重新打开 App":
        return AppLanguage.text(message, "Accessibility is granted, but the runtime is not ready. Fully quit and reopen the app")
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
    private let onTestAction: (RemoteButtonAction) -> Void
    private let onCancelLearning: () -> Void
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
    private var inputMonitoringStatus: PermissionStatus = .notGranted
    private var accessibilityStatus: PermissionStatus = .notGranted

    init(mode: VoiceInputMode,
         onToggle: @escaping () -> Bool,
         onModeChange: @escaping (VoiceInputMode) throws -> Void,
         onLearnAction: @escaping (RemoteButtonAction) -> Void,
         onChooseApp: @escaping (String) -> Void,
         onClearMappings: @escaping () -> Void,
         onRemoveMapping: @escaping (Int) -> Void,
         onTestAction: @escaping (RemoteButtonAction) -> Void,
         onCancelLearning: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.mode = mode
        self.onToggle = onToggle
        self.onModeChange = onModeChange
        self.onLearnAction = onLearnAction
        self.onChooseApp = onChooseApp
        self.onClearMappings = onClearMappings
        self.onRemoveMapping = onRemoveMapping
        self.onTestAction = onTestAction
        self.onCancelLearning = onCancelLearning
        self.onQuit = onQuit
        super.init()
        statusItem.menu = menu
        refresh()
    }

    func update(connected: Bool, speaking: Bool, enabled: Bool,
                learningAction: Bool, mappingCount: Int, canLearnReturn: Bool,
                permissionNotice: String?, mappings: [RemoteButtonMapping],
                detectedButtons: [DetectedRemoteButton],
                inputMonitoringStatus: PermissionStatus, accessibilityStatus: PermissionStatus) {
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
        self.inputMonitoringStatus = inputMonitoringStatus
        self.accessibilityStatus = accessibilityStatus
        mappingWindow?.update(mappings: mappings, learning: learningAction,
                              connected: connected, detectedButtons: detectedButtons,
                              inputMonitoringStatus: inputMonitoringStatus,
                              accessibilityStatus: accessibilityStatus)
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
        let alert = NSAlert()
        alert.messageText = AppLanguage.text("清除全部按键映射？", "Clear All Button Mappings?")
        alert.informativeText = AppLanguage.text("此操作无法撤销。之后需要重新学习按键。", "This cannot be undone. You will need to learn the buttons again.")
        alert.alertStyle = .warning
        let cancelButton = alert.addButton(withTitle: AppLanguage.text("取消", "Cancel"))
        let clearButton = alert.addButton(withTitle: AppLanguage.text("清除全部", "Clear All"))
        cancelButton.keyEquivalent = "\r"
        clearButton.keyEquivalent = ""

        guard alert.runModal() == .alertSecondButtonReturn else { return }
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
                onTestAction: onTestAction,
                onCancelLearning: onCancelLearning,
                onLanguageChange: { [weak self] in self?.refresh() }
            )
        }
        mappingWindow?.update(mappings: mappings, learning: learningAction,
                              connected: isRemoteConnected, detectedButtons: detectedButtons,
                              inputMonitoringStatus: inputMonitoringStatus,
                              accessibilityStatus: accessibilityStatus)
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
         onTestAction: @escaping (RemoteButtonAction) -> Void,
         onCancelLearning: @escaping () -> Void,
         onLanguageChange: @escaping () -> Void) {
        let model = MappingDashboardModel(onChooseApp: onChooseApp,
                                          onLearnReturn: onLearnReturn,
                                          onRemoveMapping: onRemoveMapping,
                                          onTestAction: onTestAction,
                                          onCancelLearning: onCancelLearning,
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
                inputMonitoringStatus: PermissionStatus, accessibilityStatus: PermissionStatus) {
        model.update(mappings: mappings, learning: learning,
                     connected: connected, detectedButtons: detectedButtons,
                     inputMonitoringStatus: inputMonitoringStatus,
                     accessibilityStatus: accessibilityStatus)
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
    @Published private(set) var focusDiagnostic = AppLanguage.text("尚无聚焦记录", "No focus attempts yet")
    @Published private(set) var inputMonitoringStatus: PermissionStatus = .notGranted
    @Published private(set) var accessibilityStatus: PermissionStatus = .notGranted
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
    private let onTestAction: (RemoteButtonAction) -> Void
    private let onCancelLearning: () -> Void
    private let onLanguageChange: () -> Void

    init(onChooseApp: @escaping (String) -> Void,
         onLearnReturn: @escaping () -> Void,
         onRemoveMapping: @escaping (Int) -> Void,
         onTestAction: @escaping (RemoteButtonAction) -> Void,
         onCancelLearning: @escaping () -> Void,
         onLanguageChange: @escaping () -> Void) {
        self.onChooseApp = onChooseApp
        self.onLearnReturn = onLearnReturn
        self.onRemoveMapping = onRemoveMapping
        self.onTestAction = onTestAction
        self.onCancelLearning = onCancelLearning
        self.onLanguageChange = onLanguageChange
    }

    func update(mappings: [RemoteButtonMapping], learning: Bool,
                connected: Bool, detectedButtons: [DetectedRemoteButton],
                inputMonitoringStatus: PermissionStatus, accessibilityStatus: PermissionStatus) {
        self.mappings = mappings
        self.learning = learning
        self.connected = connected
        self.detectedButtons = detectedButtons
        self.focusDiagnostic = UserDefaults.standard.string(forKey: "lastMappedAppFocusDiagnostic")
            ?? AppLanguage.text("尚无聚焦记录", "No focus attempts yet")
        self.inputMonitoringStatus = inputMonitoringStatus
        self.accessibilityStatus = accessibilityStatus
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
    func testMapping(_ action: RemoteButtonAction) { onTestAction(action) }
    func cancelLearning() { onCancelLearning() }
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
    @State private var selectedSection: DashboardSection = .mapping
    @State private var highlightedButton: RemoteButtonKey?

    private enum DashboardSection: String, CaseIterable, Identifiable {
        case mapping
        case permissions

        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 172)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            Group {
                switch selectedSection {
                case .mapping:
                    mappingContent
                case .permissions:
                    permissionsContent
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 1080, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(blue)
                Text("AlexaRemoteBridge")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            VStack(spacing: 5) {
                sidebarItem(.mapping,
                            title: AppLanguage.text("按键映射", "Button Mapping"),
                            systemImage: "keyboard")
                sidebarItem(.permissions,
                            title: AppLanguage.text("权限", "Permissions"),
                            systemImage: "lock.shield")
            }

            Spacer()

            Picker(AppLanguage.text("界面语言", "Language"), selection: $model.languageSelection) {
                ForEach(AppLanguage.Choice.allCases) { choice in
                    Text(choice.menuTitle).tag(choice.rawValue)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 8)
    }

    private func sidebarItem(_ section: DashboardSection, title: String, systemImage: String) -> some View {
        let selected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? blue : Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var mappingContent: some View {
        HStack(alignment: .top, spacing: 24) {
            RemoteIllustration(activeButton: highlightedButton)
                .frame(width: 205, height: 540)
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .center)
                .task(id: model.detectedButtons.first?.detectedAt) {
                    guard let latestDetection = model.detectedButtons.first else {
                        highlightedButton = nil
                        return
                    }

                    highlightedButton = latestDetection.remoteButton
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    highlightedButton = nil
                }

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    statusPill(AppLanguage.text("遥控器", "Remote"), value: model.connected ? AppLanguage.text("已连接 · 按任意普通键检测", "Connected · Press any regular button to detect") : AppLanguage.text("未连接", "Disconnected"), systemImage: "dot.radiowaves.left.and.right")
                    statusPill(AppLanguage.text("映射状态", "Mapping"), value: model.learning ? AppLanguage.text("正在学习…", "Learning…") : AppLanguage.text("已保存 \(model.mappings.count) 个", "\(model.mappings.count) saved"), systemImage: "checkmark.circle")
                    Spacer()
                    Button { model.learning ? model.cancelLearning() : model.chooseApp() } label: {
                        Label(model.learning ? AppLanguage.text("取消学习", "Cancel Learning") : AppLanguage.text("添加按键", "Add Button"),
                              systemImage: model.learning ? "xmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(blue)
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
                                    Text(button.remoteButton.map(Self.remoteButtonName)
                                         ?? button.keyCode.map(Self.keyName)
                                         ?? AppLanguage.text("HID 按键报告", "HID Button Report"))
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

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLanguage.text("最近输入框聚焦诊断", "Last Input Focus Diagnostic"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.focusDiagnostic)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button(AppLanguage.text("复制", "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.focusDiagnostic, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

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
    }

    private var permissionsContent: some View {
        let allSet = model.inputMonitoringStatus == .granted && model.accessibilityStatus == .granted
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLanguage.text("权限", "Permissions"))
                        .font(.system(size: 25, weight: .semibold))
                    Text(AppLanguage.text("在这里集中查看并完成 AlexaRemoteBridge 所需的系统授权。", "Review and grant the system permissions required by AlexaRemoteBridge."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(allSet ? AppLanguage.text("全部就绪", "All Set") : AppLanguage.text("需要处理", "Action Needed"),
                      systemImage: allSet ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(allSet ? .green : .orange)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 12) {
                permissionCard(title: AppLanguage.text("输入监控", "Input Monitoring"),
                               detail: AppLanguage.text("读取 Alexa 遥控器的实体按键。", "Read physical button presses from the Alexa remote."),
                               status: model.inputMonitoringStatus,
                               actionTitle: permissionActionTitle(model.inputMonitoringStatus),
                               action: model.openInputMonitoring)
                permissionCard(title: AppLanguage.text("辅助功能", "Accessibility"),
                               detail: AppLanguage.text("触发语音输入快捷键、执行按键映射并尝试聚焦输入框。", "Trigger voice-input shortcuts, run button mappings, and attempt to focus text fields."),
                               status: model.accessibilityStatus,
                               actionTitle: permissionActionTitle(model.accessibilityStatus),
                               action: model.openAccessibility)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(AppLanguage.text("授权后会自动确认", "Automatic status check"), systemImage: "arrow.clockwise.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text(AppLanguage.text("未授权时请打开对应系统设置。系统已授权但运行时未就绪时，请完全退出并重新打开 App；只有两项都真正生效时才显示绿色对勾。", "Open the corresponding System Settings when a permission is not granted. If permission is granted but the runtime is not ready, fully quit and reopen the app. The green check appears only when both permissions are actually ready."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            Spacer(minLength: 0)
        }
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

    private func permissionActionTitle(_ status: PermissionStatus) -> String {
        switch status {
        case .notGranted: return AppLanguage.text("前往授权…", "Grant Access…")
        case .needsRestart: return AppLanguage.text("打开设置…", "Open Settings…")
        case .granted: return AppLanguage.text("管理…", "Manage…")
        }
    }

    private func permissionCard(title: String, detail: String, status: PermissionStatus,
                               actionTitle: String, action: @escaping () -> Void) -> some View {
        let isGranted = status == .granted
        let statusText: String
        switch status {
        case .notGranted:
            statusText = AppLanguage.text("未授权 · \(detail)", "Not Granted · \(detail)")
        case .needsRestart:
            statusText = AppLanguage.text("已授权但运行时未就绪，请完全退出并重新打开 App", "Granted, but runtime is not ready. Quit and reopen the app")
        case .granted:
            statusText = AppLanguage.text("已生效 · \(detail)", "Ready · \(detail)")
        }
        return HStack(spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(statusText)
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
        let buttonTitle = RemoteButtonKey.resolve(signature: mapping.signature)
            .map(Self.remoteButtonName)
            ?? mapping.keyCode.map { AppLanguage.text("遥控器键 · \($0)", "Remote Button · \($0)") }
            ?? AppLanguage.text("HID 按键", "HID Button")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mapping.action.isApp ? "app.fill" : "return")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(mapping.action.isApp ? blue : Color(nsColor: .darkGray), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(buttonTitle).font(.system(size: 14, weight: .semibold))
                    Text(mapping.signature).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        model.testMapping(mapping.action)
                    } label: {
                        Label(AppLanguage.text("测试映射", "Test Mapping"), systemImage: "play.circle")
                    }
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

    private static func remoteButtonName(_ button: RemoteButtonKey) -> String {
        switch button {
        case .power: return AppLanguage.text("电源", "Power")
        case .microphone: return AppLanguage.text("麦克风", "Microphone")
        case .up: return AppLanguage.text("方向上", "Up")
        case .left: return AppLanguage.text("方向左", "Left")
        case .select: return AppLanguage.text("确认", "Select")
        case .right: return AppLanguage.text("方向右", "Right")
        case .down: return AppLanguage.text("方向下", "Down")
        case .back: return AppLanguage.text("返回", "Back")
        case .home: return AppLanguage.text("主页", "Home")
        case .menu: return AppLanguage.text("菜单", "Menu")
        case .rewind: return AppLanguage.text("快退", "Rewind")
        case .playPause: return AppLanguage.text("播放／暂停", "Play/Pause")
        case .fastForward: return AppLanguage.text("快进", "Fast Forward")
        case .mute: return AppLanguage.text("静音", "Mute")
        case .volumeUp: return AppLanguage.text("音量加", "Volume Up")
        case .tv: return "TV"
        case .volumeDown: return AppLanguage.text("音量减", "Volume Down")
        case .prime: return "Prime"
        case .netflix: return "Netflix"
        case .disney: return "Disney+"
        case .hulu: return "Hulu"
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
    let activeButton: RemoteButtonKey?

    private let button = Color(red: 0.13, green: 0.14, blue: 0.17)
    private let highlight = Color(red: 1.0, green: 0.72, blue: 0.18)

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                keycap(.power, symbol: "power", size: 28)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 3)
            Circle()
                .fill(activeButton == .microphone ? highlight : Color(red: 0.03, green: 0.64, blue: 0.88))
                .overlay(Image(systemName: "mic.fill").font(.system(size: 15)).foregroundStyle(.white))
                .frame(width: 38, height: 38)
                .overlay(Circle().stroke(activeButton == .microphone ? .white : .clear, lineWidth: 2))
                .shadow(color: activeButton == .microphone ? highlight.opacity(0.75) : .clear, radius: 9)
                .padding(.bottom, 2)
            ZStack {
                Circle().fill(Color.black.opacity(0.68)).frame(width: 126, height: 126)
                Circle()
                    .fill(activeButton == .select ? highlight : Color(red: 0.13, green: 0.14, blue: 0.17))
                    .frame(width: 57, height: 57)
                    .overlay(Circle().stroke(activeButton == .select ? .white : .clear, lineWidth: 2))
                    .shadow(color: activeButton == .select ? highlight.opacity(0.7) : .clear, radius: 8)
                direction(.up, symbol: "chevron.up").offset(y: -48)
                direction(.down, symbol: "chevron.down").offset(y: 48)
                direction(.left, symbol: "chevron.left").offset(x: -48)
                direction(.right, symbol: "chevron.right").offset(x: 48)
            }
            HStack(spacing: 13) {
                keycap(.back, symbol: "arrow.uturn.backward", size: 29)
                keycap(.home, symbol: "house.fill", size: 29)
                keycap(.menu, symbol: "line.3.horizontal", size: 29)
            }
            HStack(spacing: 13) {
                keycap(.rewind, symbol: "backward.end.fill", size: 29)
                keycap(.playPause, symbol: "playpause.fill", size: 29)
                keycap(.fastForward, symbol: "forward.end.fill", size: 29)
            }
            HStack(spacing: 13) {
                keycap(.mute, symbol: "speaker.slash.fill", size: 29)
                volumeRocker
                keycap(.tv, symbol: "tv", size: 29)
            }
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    capsuleKey(.prime, title: "prime", color: Color(red: 0.04, green: 0.45, blue: 0.91))
                    capsuleKey(.netflix, title: "NETFLIX", color: Color(red: 0.91, green: 0.08, blue: 0.10))
                }
                HStack(spacing: 7) {
                    capsuleKey(.disney, title: "Disney+", color: Color(red: 0.12, green: 0.19, blue: 0.75))
                    capsuleKey(.hulu, title: "hulu", color: Color(red: 0.02, green: 0.73, blue: 0.42), foreground: .black)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 15)
        .frame(width: 160, height: 520)
        .background(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 48))
        .overlay(RoundedRectangle(cornerRadius: 48).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        .animation(.easeOut(duration: 0.15), value: activeButton)
    }

    private func keycap(_ key: RemoteButtonKey, symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(activeButton == key ? highlight : button, in: Circle())
            .overlay(Circle().stroke(activeButton == key ? .white : .clear, lineWidth: 1.5))
            .shadow(color: activeButton == key ? highlight.opacity(0.75) : .clear, radius: 8)
    }

    private func direction(_ key: RemoteButtonKey, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 22, height: 22)
            .background(activeButton == key ? highlight : .clear, in: Circle())
            .overlay(Circle().stroke(activeButton == key ? .white : .clear, lineWidth: 1.5))
            .shadow(color: activeButton == key ? highlight.opacity(0.75) : .clear, radius: 8)
    }

    private var volumeRocker: some View {
        VStack(spacing: 0) {
            volumeButton(.volumeUp, symbol: "plus")
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            volumeButton(.volumeDown, symbol: "minus")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 30, height: 55)
        .background(button, in: Capsule())
        .overlay(Capsule().stroke(activeButton == .volumeUp || activeButton == .volumeDown ? highlight : .clear, lineWidth: 2))
        .shadow(color: activeButton == .volumeUp || activeButton == .volumeDown ? highlight.opacity(0.65) : .clear, radius: 7)
    }

    private func volumeButton(_ key: RemoteButtonKey, symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(activeButton == key ? highlight : .clear, in: Capsule())
    }

    private func capsuleKey(_ key: RemoteButtonKey, title: String, color: Color, foreground: Color = .white) -> some View {
        Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(foreground)
            .frame(width: 49, height: 23)
            .background(color.gradient, in: Capsule())
            .overlay(Capsule().stroke(activeButton == key ? highlight : .clear, lineWidth: 3))
            .shadow(color: activeButton == key ? highlight.opacity(0.8) : .clear, radius: 8)
    }
}
