#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

// MARK: - Settings page scaffolding
//
// The one way to write a settings page (design system "SettingsPage"): the
// page title lives in the detail title row, then a one-line subtitle, then
// sections. A section is a head (600 12.5/17 text-secondary + optional small
// action), a bg-content group at radius-control inside a 1px separator ring,
// and an optional 12/17 footnote. Rows are 44pt with 16/8 padding and a
// full-width hairline between them. The content column is capped at 760 and
// left-aligned; the detail background (bg-window + quiet ambient) belongs to
// the host.

/// Caps the inner column only — never the page background. Left-aligned.
struct SettingsContentColumn<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: LingXiMetrics.Column.settings, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One quiet line under the title row saying what the page does.
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

/// Page root: ScrollView + subtitle + sections, 20pt apart.
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
        ScrollView(.vertical, showsIndicators: false) {
            SettingsContentColumn {
                LXSettingsPageHeader(title: title, subtitle: subtitle)
                    .padding(.bottom, LingXiMetrics.Space.xl)
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) { content }
            }
            .padding(.horizontal, LingXiMetrics.Space.xxl)
            .padding(.bottom, LingXiMetrics.Space.xxxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One settings section: head, group container, footnote.
///
/// By default every child view is one row: 16/8 padding, 44pt minimum and a
/// full-width hairline to the next row. `rowSpacing: 0` keeps the older
/// contract where rows pad themselves and the page draws its own dividers.
struct LXSettingsCard<Title: View, Accessory: View, Content: View, Footer: View>: View {
    let title: Title
    var rowSpacing: CGFloat
    let accessory: Accessory
    let content: Content
    let footer: Footer

    init(title: Title,
         rowSpacing: CGFloat = LingXiMetrics.Space.md,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.rowSpacing = rowSpacing
        self.accessory = accessory()
        self.content = content()
        self.footer = footer()
    }

    /// `rowSpacing: 0` marks a hairline row list whose rows pad themselves.
    private var isRowList: Bool { rowSpacing == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: LingXiMetrics.Space.md) {
                title
                    .font(LXType.sectionHead)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: LingXiMetrics.Space.sm)
                accessory
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
            }
            .padding(.horizontal, LingXiMetrics.Space.xs)
            .padding(.bottom, LingXiMetrics.Space.sm)

            Group {
                if isRowList {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .environment(\.lxSettingsRowInset, LingXiMetrics.Space.lg)
                } else {
                    _VariadicView.Tree(LXSettingsRowsLayout()) { content }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lxPanel(LXColor.content, cornerRadius: LingXiMetrics.Radius.control)

            footer
                .font(LXType.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, LingXiMetrics.Space.xs)
                .padding(.top, LingXiMetrics.Space.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays each child out as a settings row with a hairline between rows.
private struct LXSettingsRowsLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                    .frame(maxWidth: .infinity, minHeight: LingXiMetrics.Size.formRow - 2 * LingXiMetrics.Space.sm,
                           alignment: .leading)
                    .padding(.horizontal, LingXiMetrics.Space.lg)
                    .padding(.vertical, LingXiMetrics.Space.sm)
                if child.id != children.last?.id { LXSettingsDivider() }
            }
        }
    }
}

extension LXSettingsCard where Title == LXSettingsSectionHeader, Footer == EmptyView {
    init(_ title: String,
         rowSpacing: CGFloat = LingXiMetrics.Space.md,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.init(title: LXSettingsSectionHeader(title), rowSpacing: rowSpacing,
                  accessory: accessory, content: content, footer: { EmptyView() })
    }
}

extension LXSettingsCard where Title == LXSettingsSectionHeader, Footer == Text {
    init(_ title: String,
         subtitle: String,
         rowSpacing: CGFloat = LingXiMetrics.Space.md,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.init(title: LXSettingsSectionHeader(title), rowSpacing: rowSpacing,
                  accessory: accessory, content: content, footer: { Text(subtitle) })
    }
}

extension LXSettingsCard where Footer == EmptyView {
    init(title: Title,
         rowSpacing: CGFloat = LingXiMetrics.Space.md,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.init(title: title, rowSpacing: rowSpacing, accessory: accessory, content: content,
                  footer: { EmptyView() })
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        LXSettingsScrollPage(title: "通用", subtitle: "Core 连接、工作区目录与启动行为。") {
            LXSettingsCard("Core") {
                LabeledContent {
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        Text(linkLabel).font(LXType.body).foregroundStyle(.primary)
                        if store.client != nil {
                            Button("关闭工作区") { Task { await store.disconnectCore() } }
                                .buttonStyle(LXButtonStyle(.secondary, size: .small))
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
                            .font(LXType.mono)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                        #if os(macOS)
                        Button("选择…", action: chooseWorkspace)
                            .buttonStyle(LXButtonStyle(.secondary, size: .small))
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
                }
            }

            LXSettingsCard("启动与运行") {
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
            }
        }
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

    #endif
}

// MARK: - Appearance

struct AppearanceSettingsPage: View {
    @AppStorage(LXPreferenceKey.colorScheme) private var scheme = ColorSchemePreference.system
    @AppStorage(LXPreferenceKey.atmosphere) private var atmosphere = AtmospherePreference.subtle
    @AppStorage(LXPreferenceKey.panelMaterial) private var panel = PanelMaterialPreference.clear
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        LXSettingsScrollPage(title: "外观", subtitle: "界面配色模式、背景氛围与浮动面板材质。") {
            LXSettingsCard("主题") {
                LabeledContent("配色模式") {
                    Picker("配色模式", selection: $scheme) {
                        ForEach(ColorSchemePreference.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .lxSettingsRow()
                .settingsAnchor("appearance.scheme")
            }

            LXSettingsCard(title: LXSettingsSectionHeader("材质")) {
                LabeledContent {
                    Picker("背景氛围", selection: $atmosphere) {
                        ForEach(AtmospherePreference.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text("背景氛围")
                        InfoHint("工作区舞台的靛蓝 / 青色氛围光强度：关闭 · 柔和 · 浓郁。静态绘制，不做动画。")
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("appearance.atmosphere")

                LabeledContent {
                    Picker("浮动面板材质", selection: $panel) {
                        ForEach(PanelMaterialPreference.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text("浮动面板材质")
                        InfoHint("通透：更多透出背景；沉稳：加深着色，文字对比更高。")
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("appearance.panel")
            } footer: {
                Text(reduceTransparency
                     ? "系统已开启「降低透明度」，浮动面板改用不透明底色，材质选项暂不生效。"
                     : "开启系统「降低透明度」时，浮动面板改用不透明底色，材质选项暂不生效。")
            }
        }
    }
}

// MARK: - Conversation

struct ConversationSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @AppStorage(LXPreferenceKey.sendKey) private var sendKey = SendKeyPreference.returnKey

    var body: some View {
        LXSettingsScrollPage(title: "对话", subtitle: "时间线的默认展开方式与消息发送按键。") {
            LXSettingsCard("时间线") {
                Toggle(isOn: Binding(get: { store.preferences.expandThinking ?? false },
                                     set: { store.setExpandThinking($0) })) {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text("默认展开思考")
                        InfoHint("关闭时仅展开较短的思考块。终端界面也使用这一设置。")
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
            }

            LXSettingsCard("输入") {
                LabeledContent("发送方式") {
                    Picker("发送方式", selection: $sendKey) {
                        ForEach(SendKeyPreference.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .lxSettingsRow()
                .settingsAnchor("conversation.sendKey")
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsPage: View {
    private let groups: [(String, [(String, String)])] = [
        ("会话", [("新建会话", "⌘N"), ("打开工作区", "⌘O"), ("发送消息", "⏎ / ⌘⏎"), ("换行", "⇧⏎ / ⏎"),
                 ("停止当前运行", "⌘."), ("快速侧问浮窗", "⌥Space")]),
        ("Composer", [("命令", "/"), ("引用文件", "@ 或拖入"), ("审批：允许一次", "⏎"), ("审批：拒绝", "esc")]),
        ("视图", [("命令面板", "⌘K"), ("显示或隐藏导航面板", "⌃⌘S"),
                 ("浏览器 / 终端 / Git 面板", "⌥⌘1 – ⌥⌘3"), ("运行轨迹窗口", "⌥⌘L")]),
        ("应用", [("设置", "⌘,")]),
    ]

    var body: some View {
        LXSettingsScrollPage(title: "快捷键", subtitle: "会话、Composer、视图与应用级的键盘快捷键参考。") {
            ForEach(groups, id: \.0) { group in
                LXSettingsCard(group.0) {
                    ForEach(group.1, id: \.0) { item in
                        LabeledContent(item.0) { LXKeyCap(item.1) }
                            .lxSettingsRow()
                    }
                }
            }
            .settingsAnchor("shortcuts.list")
        }
    }
}

/// Key cap for the shortcuts page: mono text on fill-control, radius-sm.
struct LXKeyCap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(LXType.monoSmall)
            .foregroundStyle(.primary)
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .frame(minHeight: LXControl.small)
            .background(LXColor.fillControl, in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
    }
}

#endif
