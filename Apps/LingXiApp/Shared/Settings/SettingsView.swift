#if canImport(SwiftUI)
import SwiftUI

/// Settings window: one sidebar (grouped pages, or search results while a
/// query is typed) and one continuous content pane. No tab strip, no nested split.
public struct SettingsView: View {
    @ObservedObject public var store: SettingsStore
    @AppStorage(LXPreferenceKey.colorScheme) private var scheme = ColorSchemePreference.system

    @State private var page: SettingsPage? = .general
    @State private var query = ""
    @State private var highlight: String?

    public init(store: SettingsStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(SettingsPage.Group.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(group.pages) { page in
                                Label(page.title, systemImage: page.symbol)
                                    .tag(page)
                            }
                        }
                    }
                } else {
                    searchResults
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "搜索设置")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPageView(page: page ?? .general, store: store)
                .environment(\.settingsHighlight, highlight)
                .id(page)
        }
        .navigationTitle(page?.title ?? "设置")
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
        .preferredColorScheme(scheme.colorScheme)
        .task {
            if store.client != nil { await store.refresh() }
        }
    }

    // MARK: Search

    private var results: [SettingsSearchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return (SettingsSearchIndex.staticItems + dynamicItems).filter { $0.matches(q) }
    }

    /// Live entities are indexed from the store so a provider, model or MCP
    /// server can be found by its own name.
    private var dynamicItems: [SettingsSearchItem] {
        store.providers.map { SettingsSearchItem(anchor: "provider.\($0.id)", page: .providers,
                                                 title: $0.displayName, keywords: [$0.productID, $0.id]) }
        + store.models.map { SettingsSearchItem(anchor: "model.\($0.id)", page: .models,
                                                title: $0.displayName, keywords: [$0.modelID, $0.providerID]) }
        + store.extensions.map { ext in
            SettingsSearchItem(anchor: "extension.\(ext.id)", page: ext.kind == .mcp ? .mcp : .extensions,
                               title: ext.id, keywords: [ext.kind.rawValue, ext.summary ?? ""])
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let hits = results
        if hits.isEmpty {
            Text("没有匹配「\(query)」的设置")
                .foregroundStyle(.secondary)
        } else {
            ForEach(SettingsPage.allCases.filter { p in hits.contains { $0.page == p } }) { resultPage in
                Section(resultPage.title) {
                    ForEach(hits.filter { $0.page == resultPage }) { item in
                        Button {
                            open(item)
                        } label: {
                            Label(item.title, systemImage: resultPage.symbol)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func open(_ item: SettingsSearchItem) {
        page = item.page
        highlight = item.anchor
    }
}

/// Routes to one page and scrolls to the highlighted anchor after navigation.
private struct SettingsPageView: View {
    let page: SettingsPage
    @ObservedObject var store: SettingsStore
    @Environment(\.settingsHighlight) private var highlight

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                SettingsNotice(store: store)
                if page.needsCore {
                    CoreRequiredSection(store: store)
                }
                content
            }
            .formStyle(.grouped)
            .onAppear { scroll(proxy) }
            .onChange(of: highlight) { scroll(proxy) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralSettingsPage(store: store)
        case .appearance: AppearanceSettingsPage()
        case .conversation: ConversationSettingsPage(store: store)
        case .shortcuts: ShortcutsSettingsPage()
        case .providers: ProvidersSettingsPage(store: store)
        case .models: ModelsSettingsPage(store: store)
        case .agentDefaults: AgentDefaultsSettingsPage(store: store)
        case .permissions: PermissionsSettingsPage(store: store)
        case .context: ContextSettingsPage(store: store)
        case .execution: ExecutionSettingsPage(store: store)
        case .codeIntelligence: CodeIntelligenceSettingsPage(store: store)
        case .computerUse: ComputerUseSettingsPage()
        case .mcp: ExtensionsSettingsPage(store: store, kinds: [.mcp])
        case .extensions: ExtensionsSettingsPage(store: store, kinds: [.skill, .plugin, .command, .hook])
        case .workspace: WorkspaceSettingsPage(store: store)
        case .diagnostics: DiagnosticsSettingsPage(store: store)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let highlight else { return }
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(highlight, anchor: .center) }
        }
    }
}

#endif
