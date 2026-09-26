import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    init(mode: VoiceInputMode,
         onToggle: @escaping () -> Bool,
         onModeChange: @escaping (VoiceInputMode) throws -> Void,
         onLearnAction: @escaping (RemoteButtonAction) -> Void,
         onChooseApp: @escaping (String) -> Void,
         onClearMappings: @escaping () -> Void,
         onRemoveMapping: @escaping (Int) -> Void,
         onCancelLearning: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.mode = mode
        self.onToggle = onToggle
        self.onModeChange = onModeChange
        self.onLearnAction = onLearnAction
        self.onChooseApp = onChooseApp
        self.onClearMappings = onClearMappings
        self.onRemoveMapping = onRemoveMapping
        self.onCancelLearning = onCancelLearning
        self.onQuit = onQuit
        super.init()
        statusItem.menu = menu
        refresh()
    }

    func update(connected: Bool, speaking: Bool, enabled: Bool,
                learningAction: Bool, mappingCount: Int, canLearnReturn: Bool,
                permissionNotice: String?, mappings: [RemoteButtonMapping],
                detectedButtons: [DetectedRemoteButton]) {
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
        mappingWindow?.update(mappings: mappings, learning: learningAction,
                              connected: connected, detectedButtons: detectedButtons)
        refresh()
    }

    private func refresh() {
        statusItem.button?.title = speaking ? "AR ●" : "AR"
        statusItem.button?.toolTip = connected ? "Alexa 遥控器已连接" : "Alexa 遥控器未连接"
        menu.removeAllItems()
        addStatus(connected ? "遥控器：已连接" : "遥控器：未连接")
        addStatus(speaking ? "麦克风：正在输入" : "麦克风：待机")
        addStatus("音频输出：BlackHole 2ch")
        addStatus(learningAction ? "按键学习：请按要绑定动作的遥控器按键" :
                  "按键映射：已配置 \(mappingCount) 个")
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
        let learn = NSMenuItem(title: "学习按键发送 Return…", action: #selector(learnReturn), keyEquivalent: "")
        learn.target = self
        learn.isEnabled = !learningAction && canLearnReturn
        menu.addItem(learn)
        let launch = NSMenuItem(title: "学习按键打开／切换到 App…", action: #selector(chooseApp), keyEquivalent: "")
        launch.target = self
        launch.isEnabled = !learningAction && canLearnReturn
        menu.addItem(launch)
        let settings = NSMenuItem(title: "按键映射设置…", action: #selector(openMappingSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let clear = NSMenuItem(title: "清除按键映射", action: #selector(clearMappings), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = mappingCount > 0
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
        onLearnAction(.sendReturn)
        learningAction = true
        refresh()
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "选择按键要打开或切换到的 App"
        panel.prompt = "选择 App"
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
                onCancelLearning: onCancelLearning
            )
        }
        mappingWindow?.update(mappings: mappings, learning: learningAction,
                              connected: isRemoteConnected, detectedButtons: detectedButtons)
        mappingWindow?.showWindow(nil)
        mappingWindow?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
         onCancelLearning: @escaping () -> Void) {
        let model = MappingDashboardModel(onChooseApp: onChooseApp,
                                          onLearnReturn: onLearnReturn,
                                          onRemoveMapping: onRemoveMapping,
                                          onCancelLearning: onCancelLearning)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "AlexaRemoteBridge 按键映射"
        window.center()
        self.model = model
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: MappingDashboard(model: model))
    }

    required init?(coder: NSCoder) { nil }

    private let model: MappingDashboardModel

    func update(mappings: [RemoteButtonMapping], learning: Bool,
                connected: Bool, detectedButtons: [DetectedRemoteButton]) {
        model.update(mappings: mappings, learning: learning,
                     connected: connected, detectedButtons: detectedButtons)
    }
}

@MainActor private final class MappingDashboardModel: ObservableObject {
    @Published private(set) var mappings: [RemoteButtonMapping] = []
    @Published private(set) var learning = false
    @Published private(set) var connected = false
    @Published private(set) var detectedButtons: [DetectedRemoteButton] = []
    private let onChooseApp: (String) -> Void
    private let onLearnReturn: () -> Void
    private let onRemoveMapping: (Int) -> Void
    private let onCancelLearning: () -> Void

    init(onChooseApp: @escaping (String) -> Void,
         onLearnReturn: @escaping () -> Void,
         onRemoveMapping: @escaping (Int) -> Void,
         onCancelLearning: @escaping () -> Void) {
        self.onChooseApp = onChooseApp
        self.onLearnReturn = onLearnReturn
        self.onRemoveMapping = onRemoveMapping
        self.onCancelLearning = onCancelLearning
    }

    func update(mappings: [RemoteButtonMapping], learning: Bool,
                connected: Bool, detectedButtons: [DetectedRemoteButton]) {
        self.mappings = mappings
        self.learning = learning
        self.connected = connected
        self.detectedButtons = detectedButtons
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "选择要绑定的 App"
        panel.prompt = "下一步：按遥控器键"
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
}

@MainActor private struct MappingDashboard: View {
    @ObservedObject var model: MappingDashboardModel
    private let blue = Color(red: 0.02, green: 0.62, blue: 0.86)

    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            VStack(spacing: 18) {
                RemoteIllustration()
                    .frame(width: 205, height: 540)
                Text("点击添加按键后，按一下遥控器上的实体键")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 220)
            }
            .frame(width: 240)

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    statusPill("遥控器", value: model.connected ? "已连接 · 按任意普通键检测" : "未连接", systemImage: "dot.radiowaves.left.and.right")
                    statusPill("映射状态", value: model.learning ? "正在学习…" : "已保存 \(model.mappings.count) 个", systemImage: "checkmark.circle")
                    Spacer()
                    Button { model.learning ? model.cancelLearning() : model.chooseApp() } label: {
                        Label(model.learning ? "取消学习" : "添加按键",
                              systemImage: model.learning ? "xmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(blue)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("方案").font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("默认").font(.system(size: 25, weight: .bold))
                        Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(model.mappings.count) 个按键已配置 · 本机保存")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }

                HStack {
                    Text("自定义操作").font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                    Button("添加 Return 映射") { model.learnReturn() }
                        .buttonStyle(.bordered)
                        .disabled(model.learning)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("最近检测到的按键").font(.system(size: 14)).foregroundStyle(.secondary)
                    if model.detectedButtons.isEmpty {
                        Text(model.connected ? "按一下遥控器上的任意普通按键，这里会显示检测结果。" : "连接遥控器后即可检测按键。")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(model.detectedButtons.prefix(4)) { button in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(button.keyCode.map(Self.keyName) ?? "HID 按键报告")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(button.keyCode.map { "键码 \($0) · " } ?? "") + Text(button.signature)
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
                            Text("还没有按键映射").font(.system(size: 16, weight: .semibold))
                            Text("点击右上角“添加按键”，选择目标 App，再按一下遥控器按键完成绑定。")
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

    private func mappingCard(_ mapping: RemoteButtonMapping, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mapping.action.isApp ? "app.fill" : "return")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(mapping.action.isApp ? blue : Color(nsColor: .darkGray), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("遥控器键 · \(mapping.keyCode)").font(.system(size: 14, weight: .semibold))
                    Text(mapping.signature).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("删除映射", role: .destructive) { model.removeMapping(at: index) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(6)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(15)
            Divider()
            HStack(spacing: 12) {
                Text("短按").font(.system(size: 12)).foregroundStyle(.secondary)
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
        case .sendReturn: return "发送 Return"
        case .launchApp(let path): return "打开／切换到 \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
        }
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "空格"
        case 51: return "Delete"
        case 53: return "Escape"
        case 123: return "左方向键"
        case 124: return "右方向键"
        case 125: return "下方向键"
        case 126: return "上方向键"
        default: return "按键"
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
