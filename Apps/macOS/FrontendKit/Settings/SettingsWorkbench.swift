#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

private struct SettingsSelectionKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The object picked in the master column (Provider account / MCP server id).
    var settingsSelection: String? {
        get { self[SettingsSelectionKey.self] }
        set { self[SettingsSelectionKey.self] = newValue }
    }
}

/// Settings as a sheet over the main window: category rail · object list ·
/// detail.
///
/// The middle column only exists where one object's details do not fit on a
/// row — Provider accounts and MCP servers. It is a real master–detail: the
/// middle lists every object, the detail shows only the selected one. Skills,
/// Plugins and Hooks fit on one row each and stay a single list.
struct SettingsWorkbench: View {
    @ObservedObject var store: SettingsStore
    @Binding var page: SettingsPage
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var highlight: String?
    @State private var addTrigger = 0

    /// The same window language as the workbench: the product backdrop and scrim behind,
    /// glass panels with the same 8pt gutters, the same radius, edge and elevation. It used to
    /// be three opaque `window`-grey columns split by hairlines — a different app's chrome.
    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            SettingsSidebar(store: store, selectedPage: $page, highlight: $highlight)
                .frame(width: LingXiMetrics.Column.settingsSidebar)
                .frame(maxHeight: .infinity)
                .lxPanel()

            if hasObjectList {
                objectList
                    .frame(width: LingXiMetrics.Column.settingsObjects)
                    .frame(maxHeight: .infinity)
                    .lxPanel()
            }

            VStack(alignment: .leading, spacing: 0) {
                head
                SettingsDetailView(store: store, page: page)
                    .environment(\.settingsSelection, selectedObjectID)
                    .environment(\.settingsHighlight, highlight)
                    .environment(\.settingsAddTrigger, addTrigger)
                    .environment(\.settingsSelect, { selection = $0 })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .lxPanel(LXColor.content)
            .lxSettingsControlStyles()
        }
        .padding(LingXiMetrics.Space.sm)
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 560, idealHeight: 700)
        .modifier(WallpaperWindow())
        .lxNoInitialFocus()
        .scrollIndicators(.hidden)
        .onChange(of: page) { _, next in
            selection = nil
            highlight = nil
            if !next.needsCoreData.isEmpty { Task { await store.refresh(domains: next.needsCoreData) } }
        }
    }

    /// 52pt title row: page title 20/26 semibold + close (⎋).
    private var head: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            Text(page.title)
                .font(LXType.title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(LXIconButtonStyle(side: LXControl.small))
            .help("关闭设置 (⎋)")
            .accessibilityLabel("关闭设置")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, LingXiMetrics.Space.xxl)
        .frame(height: LingXiMetrics.Size.toolbar)
    }

    // MARK: Object list

    private struct SettingObject: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let tone: Color
    }

    private var hasObjectList: Bool { page == .providers || page == .mcp }

    private var objects: [SettingObject] {
        switch page {
        case .providers:
            // Only accounts that actually exist. The registry's ~90 products are
            // picked inside 「添加账户」, not dumped into this list.
            return store.providers.map {
                SettingObject(id: $0.id, title: $0.displayName,
                              detail: [$0.productID, $0.availability == .active ? nil : $0.availability.rawValue]
                                .compactMap { $0 }.joined(separator: " · "),
                              tone: $0.availability == .active ? LXColor.success : LXColor.warning)
            }
        case .mcp:
            // mcp.json is the list; the running Core adds live state.
            return store.mcpServers.map { server in
                let live = store.extensions.first { $0.kind == .mcp && $0.id == server.id }
                let transport = server.transport == .stdio ? "stdio" : "HTTP"
                let state = !server.enabled ? "已停用" : (live?.lifecycleState ?? "未连接")
                return SettingObject(id: server.id, title: server.alias.isEmpty ? server.id : server.alias,
                                     detail: "\(transport) · \(state)",
                                     tone: live.map { ExtensionState(ext: $0).tone }
                                        ?? (server.enabled ? LXColor.warning : LXColor.separator))
            }
        default:
            return []
        }
    }

    private var selectedObjectID: String? {
        guard hasObjectList else { return nil }
        if let selection, objects.contains(where: { $0.id == selection }) { return selection }
        return objects.first?.id
    }

    private var objectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Text(page == .providers ? "\(objects.count) 个账户" : "\(objects.count) 个服务器")
                    .font(LXType.sectionHead)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(page == .providers ? "重新发现" : "重新加载") {
                    Task {
                        if page == .providers { await store.reloadProviders() } else { await store.reloadExtensions() }
                    }
                }
                .buttonStyle(LXButtonStyle(.plain, size: .small))
                .disabled(store.client == nil)
                .settingsAnchor(page == .providers ? "providers.reload" : "mcp.reload")
                Button { addTrigger += 1 } label: {
                    Image(systemName: "plus.circle").font(.system(size: LXIcon.status))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.client == nil)
                .help(page == .providers ? "添加 Provider 账户" : "添加 MCP 服务器")
                .accessibilityLabel(page == .providers ? "添加 Provider 账户" : "添加 MCP 服务器")
            }
            .padding(.horizontal, LingXiMetrics.Space.panelInset)
            .frame(height: LingXiMetrics.Size.toolbar)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if objects.isEmpty {
                        PlaceholderLine(store.client == nil ? "连接 Core 后显示。"
                                        : (page == .providers ? "Core 尚未配置 Provider 账户。" : "Core 未加载任何 MCP 服务器。"))
                            .padding(.horizontal, LingXiMetrics.Space.panelInset)
                    }
                    ForEach(objects) { object in
                        objectRow(object)
                    }
                }
                .padding(.bottom, LingXiMetrics.Space.sm)
            }
        }
    }

    private func objectRow(_ object: SettingObject) -> some View {
        let isSelected = object.id == selectedObjectID
        return Button { selection = object.id } label: {
            HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.sm) {
                Circle().fill(object.tone)
                    .frame(width: LXControl.dot, height: LXControl.dot)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                VStack(alignment: .leading, spacing: 0) {
                    Text(object.title)
                        .font(LXType.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(object.detail)
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .padding(.vertical, 6)
            .background(isSelected ? LXColor.fillControl : .clear,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Ready / failed / disabled reading of an extension's lifecycle string.
struct ExtensionState {
    let ext: ExtensionInfo

    var isError: Bool {
        let s = ext.lifecycleState.lowercased()
        return s.contains("fail") || s.contains("err") || s.contains("deg")
    }

    var isReady: Bool {
        let s = ext.lifecycleState.lowercased()
        return s.contains("ready") || s.contains("active") || s.contains("running") || (ext.enabled && !isError)
    }

    /// Colour lands on the 6pt dot only.
    var tone: Color {
        if !ext.enabled { return LXColor.separator }
        if isError { return LXStatus.error }
        if isReady { return LXStatus.success }
        return LXStatus.running
    }
}
#endif
