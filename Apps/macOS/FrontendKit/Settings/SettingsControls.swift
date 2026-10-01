#if canImport(SwiftUI)
import SwiftUI

// MARK: - Search anchors

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Anchor currently targeted by a search result on this page.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

private struct SettingsAnchorModifier: ViewModifier {
    let anchor: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content
            .id(anchor)
            // A search hit washes its row with fill-quinary; nothing else tints.
            .background(highlight == anchor ? LXColor.fillQuinary : .clear)
    }
}

extension View {
    /// Marks the row that owns a searchable setting.
    func settingsAnchor(_ anchor: String) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }
}

// MARK: - Rows

/// §7 Settings: one section head per group — 600 12.5/17 text-secondary.
/// The right-hand value (if any) drops back to regular weight; use
/// `LXSectionHead` from the Foundation layer when a value belongs on the right.
struct LXSettingsSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(LXType.sectionHead)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Horizontal inset of a row inside a group container. Grouped `Form`s already
/// inset their own rows, so the default is 0; only the explicit group
/// containers on the management pages opt in (spec §7: row padding 16).
private struct LXSettingsRowInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var lxSettingsRowInset: CGFloat {
        get { self[LXSettingsRowInsetKey.self] }
        set { self[LXSettingsRowInsetKey.self] = newValue }
    }
}

/// §7 Settings row: control text (13). A group container lays its children
/// out as 44pt rows (16/8 padding); in a self-padding row list (`rowSpacing:
/// 0`) the row pads itself to the same metrics so hairlines span the group.
private struct LXSettingsRowModifier: ViewModifier {
    @Environment(\.lxSettingsRowInset) private var inset

    func body(content: Content) -> some View {
        content
            .font(LXType.body)
            .frame(maxWidth: .infinity,
                   minHeight: inset > 0 ? LingXiMetrics.Size.formRow - 2 * LingXiMetrics.Space.sm : nil,
                   alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, inset > 0 ? LingXiMetrics.Space.sm : 0)
    }
}

extension View {
    /// Shared row scale for every Settings row, Form or group alike.
    func lxSettingsRow() -> some View {
        modifier(LXSettingsRowModifier())
    }
}

/// Settings rows put the label on the left and the control on the right.
struct LXSettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: LingXiMetrics.Space.md) {
            configuration.label
                .foregroundStyle(.primary)
            Spacer(minLength: LingXiMetrics.Space.md)
            configuration.content
        }
    }
}

/// Toggle row: label left, 32×18 switch right; on is accent.
struct LXSettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: LingXiMetrics.Space.md) {
            configuration.label
            Spacer(minLength: LingXiMetrics.Space.md)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(LXColor.accent)
        }
    }
}

extension View {
    /// Row styles shared by every settings page.
    func lxSettingsControlStyles() -> some View {
        labeledContentStyle(LXSettingsLabeledContentStyle())
            .toggleStyle(LXSettingsSwitchStyle())
            // Pop-up menus stay neutral; only a switch's on state is accent.
            .tint(Color(nsColor: .secondaryLabelColor))
    }
}

/// 1px hairline between two adjacent rows of a group (§7). Not a card, not a
/// border: the group container owns the only ring.
struct LXSettingsDivider: View {
    var body: some View {
        LXColor.separator
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Helper text on demand: hover tooltip + VoiceOver hint, keeps the page quiet.
struct InfoHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "info.circle")
            .font(LXType.meta)
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel(text)
    }
}

/// Label with optional info hint and a reset button once the key is overridden.
struct ConfigLabel<Value: Sendable>: View {
    let title: String
    var info: String?
    let key: ConfigKey<Value>
    @ObservedObject var store: SettingsStore

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Text(title)
                .font(LXType.body)
            if let info { InfoHint(info) }
            if store.isOverridden(key) {
                Button {
                    store.resetConfig(key)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(LXType.meta)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("恢复 Core 默认值")
                .accessibilityLabel("恢复 \(title) 的默认值")
            }
        }
    }
}

struct ConfigToggle: View {
    let title: String
    var info: String?
    let key: ConfigKey<Bool>
    @ObservedObject var store: SettingsStore

    var body: some View {
        Toggle(isOn: store.binding(key)) {
            ConfigLabel(title: title, info: info, key: key, store: store)
        }
        .lxSettingsRow()
        .settingsAnchor(key.id)
    }
}

struct ConfigPicker: View {
    let title: String
    var info: String?
    let key: ConfigKey<String>
    let options: [(value: String, label: String)]
    @ObservedObject var store: SettingsStore

    var body: some View {
        LabeledContent {
            Picker(selection: store.binding(key)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: { EmptyView() }
            .labelsHidden()
            .fixedSize()
        } label: {
            ConfigLabel(title: title, info: info, key: key, store: store)
        }
        .lxSettingsRow()
        .settingsAnchor(key.id)
    }
}

/// Numeric field committed on Return / focus loss; the Core default shows as
/// the placeholder value until overridden.
/// A number that Core treats as an override rather than a value with a default.
///
/// Switching it off removes the key entirely, which is what makes Core fall back to deriving the
/// budget from the model window. Writing `0` would not do that — zero is a real value to the
/// planner — so an ordinary `ConfigNumberField` could not express this setting honestly.
struct ConfigOptionalNumberField: View {
    let title: String
    var info: String?
    var unit: String?
    let key: ConfigKey<Int>
    var min: Int = 1
    @ObservedObject var store: SettingsStore

    @State private var enabled = false
    @State private var value = 0

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Toggle(isOn: $enabled) {
                ConfigLabel(title: title, info: info, key: key, store: store)
            }
            .toggleStyle(.switch)
            if enabled {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    TextField(title, value: $value, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                    if let unit {
                        Text(unit).font(LXType.meta).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("未覆盖：由 Core 按模型窗口推导。")
                    .font(LXType.meta).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: enabled) { _, on in apply(on) }
        .onChange(of: value) { _, next in if enabled { commit(next) } }
        .lxSettingsRow()
    }

    private func load() {
        let stored = store.config(key)
        enabled = stored > 0
        value = stored > 0 ? stored : key.fallback
    }

    private func apply(_ on: Bool) {
        if on { commit(max(min, value == 0 ? key.fallback : value)) } else { clear() }
    }

    private func commit(_ next: Int) {
        let clamped = max(min, next)
        if clamped != next { value = clamped }
        store.writeOverride(key, clamped)
    }

    private func clear() {
        store.writeOverride(key, nil)
    }
}

/// A ratio setting in (0, 1]. `ConfigNumberField` is Int-only, and Core's schema bounds this
/// key numerically, so the clamp lives here rather than in a description of what is valid.
struct ConfigFractionField: View {
    let title: String
    var info: String?
    let key: ConfigKey<Double>
    var lowerExclusive: Double = 0
    var upper: Double = 1
    @ObservedObject var store: SettingsStore

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Slider(value: binding(key.fallback), in: (lowerExclusive + 0.01)...upper, step: 0.01)
                    .frame(width: 140)
                Text(binding(key.fallback).wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(LXType.meta).foregroundStyle(.secondary).monospacedDigit()
            }
        } label: {
            ConfigLabel(title: title, info: info, key: key, store: store)
        }
        .lxSettingsRow()
    }

    private func binding(_ fallback: Double) -> Binding<Double> {
        Binding(
            get: { store.config(key) },
            set: { store.writeOverride(key, min(upper, max(lowerExclusive + 0.001, $0))) }
        )
    }
}

struct ConfigNumberField: View {
    let title: String
    var info: String?
    var unit: String?
    let key: ConfigKey<Int>
    @ObservedObject var store: SettingsStore

    var body: some View {
        LabeledContent {
            HStack(spacing: LingXiMetrics.Space.xs) {
                TextField(title, value: store.binding(key), format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                if let unit {
                    Text(unit)
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            ConfigLabel(title: title, info: info, key: key, store: store)
        }
        .lxSettingsRow()
        .settingsAnchor(key.id)
    }
}

struct ConfigSecondsField: View {
    let title: String
    var info: String?
    let key: ConfigKey<Double>
    @ObservedObject var store: SettingsStore

    var body: some View {
        LabeledContent {
            HStack(spacing: LingXiMetrics.Space.xs) {
                TextField(title, value: store.binding(key), format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                Text("秒")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }
        } label: {
            ConfigLabel(title: title, info: info, key: key, store: store)
        }
        .lxSettingsRow()
        .settingsAnchor(key.id)
    }
}

// MARK: - Core state

/// Banner above a page that needs a live Core: says why the page is empty and
/// offers the one action that fixes it.
struct CoreRequiredSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        if store.client == nil {
            SettingsBanner {
                HStack(spacing: LingXiMetrics.Space.md) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(LXType.headline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                        Text("未连接 Core")
                            .font(LXType.callout)
                        Text(linkDetail)
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    ConnectCoreButton(store: store)
                }
            }
        }
    }

    private var linkDetail: String {
        if case .failed(let message) = store.link { return message }
        return "此页内容由正在运行的 Core 提供。连接后读取真实状态，所有修改直接作用于 Core。"
    }
}

struct ConnectCoreButton: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        if store.link == .connecting {
            ProgressView()
        } else {
            Button("连接 Core") {
                Task { await store.connectCore() }
            }
            .controlSize(.large)
            .disabled(store.workspaceRoot.isEmpty && RecentWorkspaces.all.isEmpty)
            .accessibilityLabel("连接 Core")
            .help("在所选（或最近）工作区启动 Core")
        }
    }
}

/// Transient status banner above the page (write confirmations, failures).
struct SettingsNotice: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        if let notice = store.notice {
            SettingsBanner {
                HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.md) {
                    LXStatusText(notice, systemImage: "info.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The action that makes the notice true. `reloadConfiguration` and
                    // `restartCore` both already existed, reachable only from the Diagnostics
                    // page — a banner whose whole message is "reload required" with a single
                    // 关闭 button asked the user to go find the button themselves.
                    switch store.pendingApply {
                    case .reloadConfiguration:
                        Button("重新加载 Core") {
                            Task {
                                await store.reloadConfiguration()
                                store.notice = nil
                                store.pendingApply = .instant
                            }
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                    case .restartCore:
                        Button("重启 Core") {
                            Task {
                                await store.restartCore()
                                store.notice = nil
                                store.pendingApply = .instant
                            }
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                    case .instant, .nextSession, .nextTurn:
                        EmptyView()
                    }
                    Button("关闭") { store.notice = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Page-independent banner strip at the top of a detail page. Sits in the same
/// content column as the page below it: one group surface (`LXColor.content`),
/// radius-control, 1px separator ring, no glass, no shadow, no gradient.
private struct SettingsBanner<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        SettingsContentColumn {
            content
                .padding(.horizontal, LingXiMetrics.Space.lg)
                .padding(.vertical, LingXiMetrics.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LXColor.content,
                            in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control, style: .continuous))
                .lxRing(cornerRadius: LingXiMetrics.Radius.control)
        }
        .padding(.horizontal, LingXiMetrics.Space.xxl)
        .padding(.top, LingXiMetrics.Space.lg)
        .frame(maxWidth: .infinity)
    }
}

/// Key–value row for read-only live data. §7: key text-secondary, value text-primary.
struct ValueRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(monospaced ? LXType.mono : LXType.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .lxSettingsRow()
    }
}

#endif

#if canImport(SwiftUI)
import LingXiProtocol

// MARK: - Editing rows (providers.json / mcp.json forms)

/// Text row: label left, 280pt field right; URLs, commands and IDs are mono.
struct LXTextRow: View {
    let title: String
    var info: String?
    @Binding var text: String
    var prompt: String = ""
    var monospaced = false

    var body: some View {
        LabeledContent {
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? LXType.mono : LXType.body)
                .frame(width: 280)
        } label: {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text(title)
                if let info { InfoHint(info) }
            }
        }
        .lxSettingsRow()
    }
}

/// Number row: 96pt tabular field + unit. Empty means "not set" when optional.
///
/// Override semantics (design system 「数值」): an unset field shows the default
/// value in secondary colour; once the user has overridden it the field reads
/// primary and 「恢复默认」 appears to its left.
struct LXNumberRow: View {
    let title: String
    var info: String?
    @Binding var value: Int?
    var unit: String?
    /// The value the field falls back to; shown as the placeholder when not overridden.
    var defaultValue: Int?
    /// Present only while this field carries a user override.
    var reset: (() -> Void)?

    var body: some View {
        LabeledContent {
            HStack(spacing: LingXiMetrics.Space.xs) {
                if let reset {
                    Button("恢复默认", action: reset)
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                }
                TextField(title, value: $value, format: .number, prompt: promptText)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(LXType.body.monospacedDigit())
                    .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                    .frame(width: 96)
                if let unit { Text(unit).font(LXType.meta).foregroundStyle(.secondary) }
            }
        } label: {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text(title)
                if let info { InfoHint(info) }
            }
        }
        .lxSettingsRow()
    }

    private var promptText: Text {
        if let defaultValue { return Text(defaultValue, format: .number) }
        return Text("—")
    }
}

/// Boolean settings row with the same override semantics as `LXNumberRow`.
struct LXOverrideToggle: View {
    let title: String
    var info: String?
    /// `nil` while the value follows the model catalog.
    @Binding var override: Bool?
    /// The value to show when there is no override.
    let defaultValue: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: LingXiMetrics.Space.xs) {
                if override != nil {
                    Button("恢复默认") { override = nil }
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                }
                Toggle(title, isOn: Binding(
                    get: { override ?? defaultValue },
                    set: { override = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(LXColor.accent)
            }
        } label: {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text(title)
                if let info { InfoHint(info) }
            }
        }
        .lxSettingsRow()
    }
}

extension Binding where Value == Int {
    /// Adapts a required number to `LXNumberRow`; clearing the field keeps the value.
    var optional: Binding<Int?> {
        Binding<Int?>(get: { wrappedValue }, set: { if let new = $0 { wrappedValue = new } })
    }
}

/// Secret row: dots + 「替换…」 when stored; never shows or reads back a value.
/// The typed value only lives in `pending` until the form is saved.
struct LXSecretRow: View {
    let title: String
    var info: String?
    let stored: SecretSource
    @Binding var pending: SecretUpdate
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        LabeledContent {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Text(stateText)
                    .font(isDots || isEnvironment ? LXType.mono : LXType.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(isEnvironment ? "运行时从环境变量读取" : "")
                    .accessibilityLabel(accessibilityState)
                Button(buttonTitle) { draft = ""; isEditing = true }
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
                    .popover(isPresented: $isEditing, arrowEdge: .bottom) { editor }
            }
        } label: {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text(title)
                if let info { InfoHint(info) }
            }
        }
        .lxSettingsRow()
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            Text(title).font(LXType.headline)
            SecureField("粘贴新的值", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(LXType.mono)
                .frame(width: 300)
                .onSubmit(commit)
            HStack(spacing: LingXiMetrics.Space.sm) {
                if hasValue {
                    Button("清除") { pending = .clear; isEditing = false }
                        .buttonStyle(LXButtonStyle(.destructive, size: .small))
                }
                Spacer(minLength: 0)
                Button("取消") { isEditing = false }
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
                Button("确定", action: commit)
                    .buttonStyle(LXButtonStyle(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(LingXiMetrics.Space.lg)
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        pending = .replace(value)
        draft = ""
        isEditing = false
    }

    private var hasValue: Bool {
        switch pending {
        case .replace, .staged: return true
        case .clear: return false
        case .keep: return stored != .none
        }
    }

    private var isDots: Bool {
        if case .keep = pending, stored == .vault { return true }
        return false
    }

    private var stateText: String {
        switch pending {
        case .replace, .staged: return "将替换（未保存）"
        case .clear: return "将清除（未保存）"
        case .keep:
            switch stored {
            case .none: return "未设置"
            case .vault: return "••••••••••••"
            case .environment(let name): return "$\(name)"
            }
        }
    }

    private var isEnvironment: Bool {
        if case .keep = pending, case .environment = stored { return true }
        return false
    }

    private var accessibilityState: String {
        if isDots { return "已保存" }
        if case .keep = pending, case .environment(let name) = stored { return "来自环境变量 \(name)" }
        return stateText
    }

    private var buttonTitle: String { hasValue ? "替换…" : "设置…" }
}

/// Key–value list: one row per pair (two fields + delete) and an 「添加…」 row.
struct LXKeyValueEditor: View {
    @Binding var pairs: [KeyValuePair]
    let keyPrompt: String
    let valuePrompt: String
    let addTitle: String

    struct KeyValuePair: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key && lhs.value == rhs.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            ForEach($pairs) { $pair in
                HStack(spacing: LingXiMetrics.Space.sm) {
                    TextField(keyPrompt, text: $pair.key)
                        .textFieldStyle(.roundedBorder)
                        .font(LXType.mono)
                    TextField(valuePrompt, text: $pair.value)
                        .textFieldStyle(.roundedBorder)
                        .font(LXType.mono)
                    Button {
                        pairs.removeAll { $0.id == pair.id }
                    } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("删除 \(pair.key)")
                }
            }
            Button {
                pairs.append(KeyValuePair(key: "", value: ""))
            } label: {
                Label(addTitle, systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(LXColor.accentText)
        }
        .lxSettingsRow()
    }

    static func pairs(from dictionary: [String: String]) -> [KeyValuePair] {
        dictionary.keys.sorted().map { KeyValuePair(key: $0, value: dictionary[$0] ?? "") }
    }

    static func dictionary(from pairs: [KeyValuePair]) -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = pair.value }
        }
        return result
    }
}

// MARK: - Master–detail plumbing

private struct SettingsAddTriggerKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct SettingsSelectKey: EnvironmentKey {
    static let defaultValue: @MainActor (String?) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Bumped by the master column's 「＋」; the page presents its add form.
    var settingsAddTrigger: Int {
        get { self[SettingsAddTriggerKey.self] }
        set { self[SettingsAddTriggerKey.self] = newValue }
    }

    /// Selects an object in the master column (after adding one).
    var settingsSelect: @MainActor (String?) -> Void {
        get { self[SettingsSelectKey.self] }
        set { self[SettingsSelectKey.self] = newValue }
    }
}
#endif
