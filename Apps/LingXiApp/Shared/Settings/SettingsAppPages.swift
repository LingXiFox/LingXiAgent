#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol
#if os(macOS)
import AppKit
#endif

// MARK: - General

struct GeneralSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text(linkLabel).foregroundStyle(.secondary)
                    if store.client != nil {
                        Button("关闭工作区") { Task { await store.disconnectCore() } }
                    } else {
                        ConnectCoreButton(store: store)
                    }
                }
            } label: {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("Core 连接")
                    InfoHint("设置与主窗口共用同一个 Core 连接，不会启动第二个 Core 进程。")
                }
            }
            .settingsAnchor("core.link")

            LabeledContent {
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text(store.runtime?.workspaceURL?.path ?? (store.workspaceRoot.isEmpty ? "未选择" : store.workspaceRoot))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    #if os(macOS)
                    Button("选择…", action: chooseWorkspace)
                        .disabled(store.client != nil)
                    #endif
                }
            } label: {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("工作区目录")
                    InfoHint("Core 以此目录为工作区启动。连接后如需更换，请先关闭当前工作区。")
                }
            }
            .settingsAnchor("core.workspace")

            if case .failed(let message) = store.link {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Core")
        }

        Section("启动与运行") {
            Toggle("启动时打开上次的工作区", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: LXPreferenceKey.reopenLastWorkspace) as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: LXPreferenceKey.reopenLastWorkspace); store.objectWillChange.send() }))
                .settingsAnchor("general.reopen")
            Toggle(isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: LXPreferenceKey.preventSleepWhileRunning) },
                set: { UserDefaults.standard.set($0, forKey: LXPreferenceKey.preventSleepWhileRunning); store.objectWillChange.send() })) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("运行 Agent 时阻止系统睡眠")
                    InfoHint("仅在有任务运行时生效，任务结束即恢复。显示器仍可按系统设置熄灭。")
                }
            }
            .settingsAnchor("general.sleep")
        }

        Section {
            if !store.isConfigReadable {
                Label("config.json 无法解析，设置页不会覆盖它。请手动修正后重新打开。",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            #if os(macOS)
            ForEach(["config.json", "providers.json", "mcp.json", "preferences.json"], id: \.self) { name in
                LabeledContent(name) {
                    Button("在 Finder 中显示") { reveal(LingXiDataRoot.file(name)) }
                        .buttonStyle(.link)
                }
            }
            #endif
        } header: {
            Text("配置文件")
        } footer: {
            Text(LingXiDataRoot.url.path)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .settingsAnchor("files")
    }

    private var linkLabel: String {
        switch store.link {
        case .offline: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return store.runtimeInfo.map { "已连接 · v\($0.version)" } ?? "已连接"
        case .failed: return "连接失败"
        }
    }

    #if os(macOS)
    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择工作区"
        if panel.runModal() == .OK, let url = panel.url {
            store.workspaceRoot = url.path
        }
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
    #endif
}

// MARK: - Appearance

struct AppearanceSettingsPage: View {
    @AppStorage(LXPreferenceKey.colorScheme) private var scheme = ColorSchemePreference.system
    @AppStorage(LXPreferenceKey.atmosphere) private var atmosphere = AtmospherePreference.subtle
    @AppStorage(LXPreferenceKey.panelMaterial) private var panel = PanelMaterialPreference.clear
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Section("主题") {
            Picker("配色模式", selection: $scheme) {
                ForEach(ColorSchemePreference.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .settingsAnchor("appearance.scheme")
        }

        Section {
            Picker(selection: $atmosphere) {
                ForEach(AtmospherePreference.allCases) { Text($0.label).tag($0) }
            } label: {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("背景氛围")
                    InfoHint("主窗口背后的静态环境光。只在窗口尺寸变化时重绘，不做动画。")
                }
            }
            .pickerStyle(.segmented)
            .settingsAnchor("appearance.atmosphere")

            Picker(selection: $panel) {
                ForEach(PanelMaterialPreference.allCases) { Text($0.label).tag($0) }
            } label: {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("浮动面板材质")
                    InfoHint("通透：更多透出背景；沉稳：加深着色，文字对比更高。")
                }
            }
            .pickerStyle(.segmented)
            .settingsAnchor("appearance.panel")
        } header: {
            Text("材质")
        } footer: {
            if reduceTransparency {
                Text("系统已开启「降低透明度」，浮动面板改用不透明底色，以上材质选项暂不生效。")
            }
        }
    }
}

// MARK: - Conversation

struct ConversationSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @AppStorage(LXPreferenceKey.sendKey) private var sendKey = SendKeyPreference.returnKey

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { store.preferences.expandThinking ?? false },
                                 set: { store.setExpandThinking($0) })) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("默认展开思考")
                    InfoHint("关闭时仅展开较短的思考块。与终端界面共用 preferences.json。")
                }
            }
            .settingsAnchor("conversation.thinking")

            Toggle(isOn: Binding(get: { store.preferences.expandTools ?? false },
                                 set: { store.setExpandTools($0) })) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("默认展开工具输出")
                    InfoHint("关闭时仅展开失败与写入类工具的输出。")
                }
            }
            .settingsAnchor("conversation.tools")
        } header: {
            Text("时间线")
        }

        Section("输入") {
            Picker("发送方式", selection: $sendKey) {
                ForEach(SendKeyPreference.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .settingsAnchor("conversation.sendKey")
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsPage: View {
    private let groups: [(String, [(String, String)])] = [
        ("会话", [("新建会话", "⌘N"), ("打开工作区", "⌘O"), ("发送消息", "⏎ / ⌘⏎"), ("换行", "⇧⏎ / ⏎"),
                 ("停止当前运行", "⌘."), ("快速侧问浮窗", "⌥Space")]),
        ("Composer", [("命令", "/"), ("引用文件", "@ 或拖入"), ("审批：允许一次", "⏎"), ("审批：拒绝", "esc")]),
        ("视图", [("命令面板", "⌘K"), ("显示或隐藏导航面板", "⌃⌘S"), ("显示或隐藏检查器", "⌥⌘I"),
                 ("检查器标签", "⌥⌘1 – ⌥⌘5"), ("运行轨迹窗口", "⌥⌘L")]),
        ("应用", [("设置", "⌘,")]),
    ]

    var body: some View {
        ForEach(groups, id: \.0) { group in
            Section(group.0) {
                ForEach(group.1, id: \.0) { item in
                    LabeledContent(item.0) {
                        Text(item.1)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsAnchor("shortcuts.list")
    }
}

#endif
