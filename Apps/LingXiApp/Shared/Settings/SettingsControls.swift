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
            // The search hit is the only tinted state here, and it uses the brand
            // accent-soft wash — never the system accent colour.
            .listRowBackground(highlight == anchor ? LXColor.accentSoft : nil)
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

/// §7 Settings row: control text (13), min-height 44, and inside a group
/// container 16 horizontal / 12 vertical padding, so the hairline that
/// separates adjacent rows spans the full group width.
private struct LXSettingsRowModifier: ViewModifier {
    @Environment(\.lxSettingsRowInset) private var inset

    func body(content: Content) -> some View {
        content
            .font(LXType.body)
            .frame(maxWidth: .infinity, minHeight: LingXiMetrics.Size.formRow, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, inset > 0 ? LingXiMetrics.Space.md : 0)
    }
}

extension View {
    /// Shared row scale for every Settings row, Form or group alike.
    func lxSettingsRow() -> some View {
        modifier(LXSettingsRowModifier())
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
        Picker(selection: store.binding(key)) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        } label: {
            ConfigLabel(title: title, info: info, key: key, store: store)
        }
        .lxSettingsRow()
        .settingsAnchor(key.id)
    }
}

/// Numeric field committed on Return / focus loss; the Core default shows as
/// the placeholder value until overridden.
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
                    .frame(width: 120)
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
                    .frame(width: 88)
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
