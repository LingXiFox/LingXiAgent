#if canImport(SwiftUI)
import SwiftUI

/// Settings sidebar: grouped pages, or live search results. Same neutral row
/// and selection as the workspace navigator.
struct SettingsSidebar: View {
    @ObservedObject var store: SettingsStore
    @Binding var selectedPage: SettingsPage
    @State private var query = ""

    init(store: SettingsStore, selectedPage: Binding<SettingsPage>) {
        self.store = store
        self._selectedPage = selectedPage
    }

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $query, prompt: "搜索设置")
                .padding(.horizontal, LingXiMetrics.Space.panelInset - 4)
                .padding(.vertical, LingXiMetrics.Space.sm)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(SettingsPage.Group.allCases) { group in
                            LXSidebarSectionHead(group.rawValue)
                            ForEach(group.pages) { page in
                                LXSidebarRow(page.title, symbol: page.symbol,
                                             isSelected: page == selectedPage) { selectedPage = page }
                            }
                        }
                    } else {
                        searchResults
                    }
                }
                .padding(.bottom, LingXiMetrics.Space.sm)
            }
        }
    }

    private var results: [SettingsSearchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return (SettingsSearchIndex.staticItems + dynamicItems).filter { $0.matches(q) }
    }

    private var dynamicItems: [SettingsSearchItem] {
        store.providers.map { SettingsSearchItem(anchor: "provider.\($0.id)", page: .providers,
                                                 title: $0.displayName, keywords: [$0.productID, $0.id]) }
        + store.extensions.map { ext in
            let page: SettingsPage
            switch ext.kind {
            case .mcp: page = .mcp
            case .skill: page = .skills
            case .plugin, .command: page = .plugins
            case .hook: page = .hooks
            }
            return SettingsSearchItem(anchor: "extension.\(ext.id)", page: page,
                                      title: ext.id, keywords: [ext.kind.rawValue, ext.summary ?? ""])
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let hits = results
        if hits.isEmpty {
            PlaceholderLine("没有匹配「\(query)」的设置。")
                .padding(LingXiMetrics.Space.panelInset)
        } else {
            ForEach(SettingsPage.allCases.filter { page in hits.contains { $0.page == page } }) { page in
                LXSidebarSectionHead(page.title)
                ForEach(hits.filter { $0.page == page }) { item in
                    LXSidebarRow(item.title, symbol: page.symbol, isSelected: false) { selectedPage = item.page }
                }
            }
        }
    }
}

// MARK: - Settings detail shell

/// Root of the Settings detail area.
///
/// Contract with the page files: a page IS the root of its own content. It fills
/// the detail area and stays transparent, capping only its inner column via
/// `SettingsContentColumn` (never the background width) — see
/// `LXSettingsScrollPage` and `View.lxSettingsFormChrome()` in
/// SettingsAppPages.swift. This root only adds what is page-independent: the
/// transient notice and the Core-required banner.
///
/// The stage's quiet ambient (§5 `is-quiet`) is painted by whoever hosts this
/// detail column — `MainStageSplitView` for the shipping window, `SettingsView`
/// below for the standalone preview — and stays a single instance. This root
/// deliberately does NOT fill itself with an opaque `LXColor.window`: doing so
/// hid the ambient and re-created the old defect of a flat gray form area with
/// a differently-coloured band beside it. Pages must not wrap themselves in a
/// second background-forming container or in another Form/ScrollView.
struct SettingsDetailRoot<Page: View>: View {
    @ObservedObject var store: SettingsStore
    let needsCore: Bool
    private let page: Page

    init(store: SettingsStore, needsCore: Bool, @ViewBuilder page: () -> Page) {
        self.store = store
        self.needsCore = needsCore
        self.page = page()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsNotice(store: store)
            if needsCore {
                CoreRequiredSection(store: store)
            }
            page
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            SettingsDetailRoot(store: store, needsCore: page.needsCore) {
                content
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
            withAnimation(LXMotion.standard) { proxy.scrollTo(highlight, anchor: .center) }
        }
    }
}

/// Standalone Settings window representation for preview or isolated testing.
/// The shipping surface embeds `SettingsDetailView` in the main split view,
/// which already lays the quiet ambient under the detail column; this root has
/// no such host, so it provides the same `is-quiet` stage itself.
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
                .navigationSplitViewColumnWidth(min: LingXiMetrics.Size.navigatorMin,
                                                ideal: LingXiMetrics.Column.settingsSidebar,
                                                max: LingXiMetrics.Size.navigator)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(store: store, page: page)
                .background {
                    AtmosphereBackdrop(mode: .settings)
                        .ignoresSafeArea()
                }
        }
        .navigationTitle(page.title)
        .frame(minWidth: LingXiMetrics.Size.windowMinWidth, idealWidth: 900,
               minHeight: LingXiMetrics.Size.windowMinHeight, idealHeight: 640)
        .preferredColorScheme(scheme.colorScheme)
        .task {
            if store.client != nil { await store.refresh() }
        }
    }
}
#endif
