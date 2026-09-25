#if canImport(SwiftUI)
import SwiftUI

/// Settings sidebar: grouped pages or live search results, conforming to native macOS sidebar behavior.
struct SettingsSidebar: View {
    @ObservedObject var store: SettingsStore
    @Binding var selectedPage: SettingsPage
    @State private var query = ""
    @State private var highlight: String?

    init(store: SettingsStore, selectedPage: Binding<SettingsPage>) {
        self.store = store
        self._selectedPage = selectedPage
    }

    public var body: some View {
        List(selection: $selectedPage) {
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
    }

    // MARK: - Search

    private var results: [SettingsSearchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return (SettingsSearchIndex.staticItems + dynamicItems).filter { $0.matches(q) }
    }

    private var dynamicItems: [SettingsSearchItem] {
        store.providers.map { SettingsSearchItem(anchor: "provider.\($0.id)", page: .providers,
                                                 title: $0.displayName, keywords: [$0.productID, $0.id]) }
        + store.extensions.map { ext in
            let targetPage: SettingsPage
            switch ext.kind {
            case .mcp: targetPage = .mcp
            case .skill: targetPage = .skills
            case .plugin: targetPage = .plugins
            case .hook: targetPage = .hooks
            case .command: targetPage = .plugins
            }
            return SettingsSearchItem(anchor: "extension.\(ext.id)", page: targetPage,
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
                            selectedPage = item.page
                        } label: {
                            Label(item.title, systemImage: resultPage.symbol)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Settings detail pane: routes to one page and scrolls to highlighted anchor.
struct SettingsDetailView: View {
    let page: SettingsPage
    @ObservedObject var store: SettingsStore
    @Environment(\.settingsHighlight) private var highlight

    init(store: SettingsStore, page: SettingsPage) {
        self.store = store
        self.page = page
    }

    public var body: some View {
        ScrollViewReader { proxy in
            SettingsContentColumn(maxWidth: 840) {
                Form {
                    SettingsNotice(store: store)
                    if page.needsCore {
                        CoreRequiredSection(store: store)
                    }
                    content
                }
                .formStyle(.grouped)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: highlight) { scroll(proxy) }
        }
        .id(page)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralSettingsPage(store: store)
        case .appearance: AppearanceSettingsPage()
        case .conversation: ConversationSettingsPage(store: store)
        case .shortcuts: ShortcutsSettingsPage()
        case .providers: ProvidersSettingsPage(store: store)
        case .agentDefaults: AgentDefaultsSettingsPage(store: store)
        case .permissions: PermissionsSettingsPage(store: store)
        case .context: ContextSettingsPage(store: store)
        case .execution: ExecutionSettingsPage(store: store)
        case .codeIntelligence: CodeIntelligenceSettingsPage(store: store)
        case .computerUse: ComputerUseSettingsPage()
        case .mcp: ExtensionsSettingsPage(store: store, kinds: [.mcp])
        case .skills: ExtensionsSettingsPage(store: store, kinds: [.skill])
        case .plugins: ExtensionsSettingsPage(store: store, kinds: [.plugin, .command])
        case .hooks: ExtensionsSettingsPage(store: store, kinds: [.hook])
        case .workspace: WorkspaceSettingsPage(store: store)
        case .diagnostics: DiagnosticsSettingsPage(store: store)
        case .about: AboutSettingsPage(store: store)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let highlight else { return }
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(highlight, anchor: .center) }
        }
    }
}

/// Standalone Settings window representation for preview or isolated testing.
public struct SettingsView: View {
    @ObservedObject public var store: SettingsStore
    @AppStorage(LXPreferenceKey.colorScheme) private var scheme = ColorSchemePreference.system
    @State private var page: SettingsPage = .general

    public init(store: SettingsStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            SettingsSidebar(store: store, selectedPage: $page)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(store: store, page: page)
        }
        .navigationTitle(page.title)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
        .preferredColorScheme(scheme.colorScheme)
        .task {
            if store.client != nil { await store.refresh() }
        }
    }
}
#endif
