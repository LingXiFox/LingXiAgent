#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

// MARK: - Settings page scaffolding
//
// Shared composition for every settings page (design system "Provider
// settings"): the page title lives in the window toolbar, the content column
// is capped at 760 and centred, groups are bg-content sections at
// radius-control inside a 1px separator ring with 44pt rows, a 600 13/18 head
// with an optional small action, and a 12/17 footnote. The detail background
// stays transparent so the quiet (40%) ambient shows at the edges.

/// Caps the inner column only — never the page background.
struct SettingsContentColumn<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: LingXiMetrics.Column.settings, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

/// One quiet line under the toolbar title saying what the page does. The
/// title itself is the window title, so it is not repeated here.
struct LXSettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        Text(subtitle)
            .font(LXType.meta)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(title)：\(subtitle)")
    }
}

/// Management-page root: ScrollView + explicit groups.
struct LXSettingsScrollPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            SettingsContentColumn {
                LXSettingsPageHeader(title: title, subtitle: subtitle)
                    .padding(.bottom, LingXiMetrics.Space.lg)
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) { content }
            }
            .padding(.horizontal, LingXiMetrics.Column.gutter)
            .padding(.top, LingXiMetrics.Space.md)
            .padding(.bottom, LingXiMetrics.Space.xxxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One settings group: head (600 13/18 + optional small action), rows on a
/// bg-content section at radius-control inside a separator ring, footnote.
struct LXSettingsCard<Title: View, Accessory: View, Content: View>: View {
    let title: Title
    var subtitle: String?
    var rowSpacing: CGFloat
    let accessory: Accessory
    let content: Content

    init(title: Title,
         subtitle: String? = nil,
         rowSpacing: CGFloat = LingXiMetrics.Space.md,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.rowSpacing = rowSpacing
        self.accessory = accessory()
        self.content = content()
    }

    /// `rowSpacing: 0` marks a hairline row list whose rows pad themselves.
    private var isRowList: Bool { rowSpacing == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: LingXiMetrics.Space.md) {
                title
                    .font(LXType.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: LingXiMetrics.Space.sm)
                accessory
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
            }
            .padding(.horizontal, LingXiMetrics.Space.xs)
            .padding(.bottom, LingXiMetrics.Space.sm)

            VStack(alignment: .leading, spacing: isRowList ? 0 : rowSpacing) { content }
                .modifier(LXSettingsGroupContentModifier(rowList: isRowList))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lxPanel(LXColor.content, cornerRadius: LingXiMetrics.Radius.control)

            if let subtitle {
                LXFootnote(subtitle)
                    .padding(.horizontal, LingXiMetrics.Space.xs)
                    .padding(.top, LingXiMetrics.Space.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Row lists pad themselves (row inset environment); other content gets one
/// 16 × 12 inset from the group.
private struct LXSettingsGroupContentModifier: ViewModifier {
    let rowList: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if rowList {
            content.environment(\.lxSettingsRowInset, LingXiMetrics.Space.lg)
        } else {
            content
                .padding(.horizontal, LingXiMetrics.Space.lg)
                .padding(.vertical, LingXiMetrics.Space.md)
        }
    }
}

extension LXSettingsCard where Title == LXSettingsSectionHeader {
    init(_ title: String,
         subtitle: String? = nil,
         rowSpacing: CGFloat = LingXiMetrics.Space.md,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.init(title: LXSettingsSectionHeader(title), subtitle: subtitle, rowSpacing: rowSpacing,
                  accessory: accessory, content: content)
    }
}

extension View {
    /// Grouped-Form pages: native grouped form on a transparent background,
    /// inner column capped like the scroll pages.
    func lxSettingsFormChrome() -> some View {
        SettingsContentColumn {
            self.formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            LXSettingsPageHeader(title: "通用",
                                 subtitle: "Core 连接、工作区目录、启动行为与配置文件位置。")
                .padding(.bottom, LingXiMetrics.Space.xl)

            Section {
                LabeledContent {
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        Text(linkLabel).font(LXType.body).foregroundStyle(.primary)
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
                .lxSettingsRow()
                .settingsAnchor("core.link")

                LabeledContent {
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        Text(store.runtime?.workspaceURL?.path ?? (store.workspaceRoot.isEmpty ? "未选择" : store.workspaceRoot))
                            .font(LXType.monoSmall)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
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
                .lxSettingsRow()
                .settingsAnchor("core.workspace")

                if case .failed(let message) = store.link {
                    LXStatusText(message, systemImage: "exclamationmark.triangle", tone: .danger)
                        .textSelection(.enabled)
                        .padding(.top, LingXiMetrics.Space.xs)
                }
            } header: {
                LXSettingsSectionHeader("Core")
            }

            Section {
                Toggle("启动时打开上次的工作区", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: LXPreferenceKey.reopenLastWorkspace) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: LXPreferenceKey.reopenLastWorkspace); store.objectWillChange.send() }))
                    .lxSettingsRow()
                    .settingsAnchor("general.reopen")
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: LXPreferenceKey.preventSleepWhileRunning) },
                    set: { UserDefaults.standard.set($0, forKey: LXPreferenceKey.preventSleepWhileRunning); store.objectWillChange.send() })) {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text("运行 Agent 时阻止系统睡眠")
                        InfoHint("仅在有任务运行时生效，任务结束即恢复。显示器仍可按系统设置熄灭。")
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("general.sleep")
            } header: {
                LXSettingsSectionHeader("启动与运行")
            }

            Section {
                if !store.isConfigReadable {
                    LXStatusText("config.json 无法解析，设置页不会覆盖它。请手动修正后重新打开。",
                                 systemImage: "exclamationmark.triangle",
                                 tone: .danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, LingXiMetrics.Space.xs)
                }
                #if os(macOS)
                ForEach(["config.json", "providers.json", "mcp.json", "preferences.json"], id: \.self) { name in
                    LabeledContent(name) {
                        Button("在 Finder 中显示") { reveal(LingXiDataRoot.file(name)) }
                            .buttonStyle(.link)
                    }
                    .lxSettingsRow()
                }
                #endif
            } header: {
                LXSettingsSectionHeader("配置文件")
            } footer: {
                Text(LingXiDataRoot.url.path)
                    .font(LXType.monoSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .settingsAnchor("files")
        }
        .lxSettingsFormChrome()
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
        Form {
            LXSettingsPageHeader(title: "外观",
                                 subtitle: "界面配色模式、背景氛围与浮动面板材质。")
                .padding(.bottom, LingXiMetrics.Space.xl)

            Section {
                Picker("配色模式", selection: $scheme) {
                    ForEach(ColorSchemePreference.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .lxSettingsRow()
                .settingsAnchor("appearance.scheme")
            } header: {
                LXSettingsSectionHeader("主题")
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
                .lxSettingsRow()
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
                .lxSettingsRow()
                .settingsAnchor("appearance.panel")
            } header: {
                LXSettingsSectionHeader("材质")
            } footer: {
                if reduceTransparency {
                    Text("系统已开启「降低透明度」，浮动面板改用不透明底色，以上材质选项暂不生效。")
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lxSettingsFormChrome()
    }
}

// MARK: - Conversation

struct ConversationSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @AppStorage(LXPreferenceKey.sendKey) private var sendKey = SendKeyPreference.returnKey

    var body: some View {
        Form {
            LXSettingsPageHeader(title: "对话",
                                 subtitle: "时间线的默认展开方式与消息发送按键。")
                .padding(.bottom, LingXiMetrics.Space.xl)

            Section {
                Toggle(isOn: Binding(get: { store.preferences.expandThinking ?? false },
                                     set: { store.setExpandThinking($0) })) {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text("默认展开思考")
                        InfoHint("关闭时仅展开较短的思考块。与终端界面共用 preferences.json。")
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("conversation.thinking")

                Toggle(isOn: Binding(get: { store.preferences.expandTools ?? false },
                                     set: { store.setExpandTools($0) })) {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text("默认展开工具输出")
                        InfoHint("关闭时仅展开失败与写入类工具的输出。")
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("conversation.tools")
            } header: {
                LXSettingsSectionHeader("时间线")
            }

            Section {
                Picker("发送方式", selection: $sendKey) {
                    ForEach(SendKeyPreference.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .lxSettingsRow()
                .settingsAnchor("conversation.sendKey")
            } header: {
                LXSettingsSectionHeader("输入")
            }
        }
        .lxSettingsFormChrome()
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
        Form {
            LXSettingsPageHeader(title: "快捷键",
                                 subtitle: "会话、Composer、视图与应用级的键盘快捷键参考。")
                .padding(.bottom, LingXiMetrics.Space.xl)

            ForEach(groups, id: \.0) { group in
                Section {
                    ForEach(group.1, id: \.0) { item in
                        LabeledContent(item.0) {
                            Text(item.1)
                                .font(LXType.monoSmall)
                                .foregroundStyle(.primary)
                        }
                        .lxSettingsRow()
                    }
                } header: {
                    LXSettingsSectionHeader(group.0)
                }
            }
            .settingsAnchor("shortcuts.list")
        }
        .lxSettingsFormChrome()
    }
}

#endif
