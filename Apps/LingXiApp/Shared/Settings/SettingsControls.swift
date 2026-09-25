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
            .listRowBackground(highlight == anchor ? Color.accentColor.opacity(0.14) : nil)
    }
}

extension View {
    /// Marks the row that owns a searchable setting.
    func settingsAnchor(_ anchor: String) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }
}

// MARK: - Rows

/// Helper text on demand: hover tooltip + VoiceOver hint, keeps the page quiet.
struct InfoHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.tertiary)
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
            if let info { InfoHint(info) }
            if store.isOverridden(key) {
                Button {
                    store.resetConfig(key)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
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
                    Text(unit).foregroundStyle(.secondary)
                }
            }
        } label: {
            ConfigLabel(title: title, info: info, key: key, store: store)
        }
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
                Text("秒").foregroundStyle(.secondary)
            }
        } label: {
            ConfigLabel(title: title, info: info, key: key, store: store)
        }
        .settingsAnchor(key.id)
    }
}

// MARK: - Core state

/// Shown at the top of pages that need a live Core: says why the page is empty
/// and offers the one action that fixes it.
struct CoreRequiredSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        if store.client == nil {
            Section {
                HStack(spacing: LingXiMetrics.Space.md) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未连接 Core").font(.headline)
                        Text(linkDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    ConnectCoreButton(store: store)
                }
                .padding(.vertical, LingXiMetrics.Space.xs)
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
            ProgressView().controlSize(.small)
        } else {
            Button("连接 Core") {
                Task { await store.connectCore() }
            }
            .disabled(store.workspaceRoot.isEmpty && RecentWorkspaces.all.isEmpty)
            .accessibilityLabel("连接 Core")
            .help("在所选（或最近）工作区启动 Core")
        }
    }
}

/// Transient status line under the page title (write confirmations, failures).
struct SettingsNotice: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        if let notice = store.notice {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("关闭") { store.notice = nil }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

/// Key–value row for read-only live data.
struct ValueRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

#endif
