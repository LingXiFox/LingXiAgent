#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

/// Settings as a modal workbench: category rail · object list · detail form.
///
/// The middle column only appears for pages that really are collections of
/// named objects — Provider accounts and the four extension kinds. Selecting an
/// object drives the same anchor-highlight plumbing the settings search uses,
/// so the detail pane scrolls to and washes the owning row. Pages without a
/// real object list stay two columns rather than growing a decorative one.
struct SettingsWorkbench: View {
    @ObservedObject var store: SettingsStore
    @Binding var page: SettingsPage
    @Environment(\.dismiss) private var dismiss

    @State private var highlight: String?

    var body: some View {
        VStack(spacing: 0) {
            head
            LXHairline()
            HStack(spacing: 0) {
                SettingsSidebar(store: store, selectedPage: $page)
                    .frame(width: LingXiMetrics.Column.settingsSidebar)
                    .background(LXColor.window)
                    .overlay(alignment: .trailing) { LXHairline() }

                if !objects.isEmpty {
                    objectList
                        .frame(width: 220)
                        .background(LXColor.window)
                        .overlay(alignment: .trailing) { LXHairline() }
                }

                SettingsDetailView(store: store, page: page)
                    .environment(\.settingsHighlight, highlight)
                    .background(LXColor.content)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 560, idealHeight: 700)
        .background(LXColor.content)
        .onChange(of: page) { _, next in
            highlight = nil
            if next.needsCore { Task { await store.refresh() } }
        }
    }

    private var head: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            Image(systemName: page.symbol)
                .font(.system(size: LXIcon.row))
                .foregroundStyle(.secondary)
            Text(page.title).font(LXType.title)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(LXIconButtonStyle(side: LXControl.small))
            .help("关闭设置 (⎋)")
            .accessibilityLabel("关闭设置")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .frame(height: LingXiMetrics.Size.sidebarHead)
    }

    // MARK: Object list

    private struct SettingObject: Identifiable, Hashable {
        let id: String
        let anchor: String
        let title: String
        let detail: String?
    }

    private var objects: [SettingObject] {
        switch page {
        case .providers:
            return store.providers.map {
                SettingObject(id: $0.id, anchor: "provider.\($0.id)",
                              title: $0.displayName, detail: $0.productID)
            }
        case .mcp, .skills, .plugins, .hooks:
            let kinds = extensionKinds(for: page)
            return store.extensions.filter { kinds.contains($0.kind) }.map {
                SettingObject(id: $0.id, anchor: "extension.\($0.id)",
                              title: $0.id, detail: $0.summary)
            }
        default:
            return []
        }
    }

    private func extensionKinds(for page: SettingsPage) -> [ExtensionKind] {
        switch page {
        case .mcp: return [.mcp]
        case .skills: return [.skill]
        case .plugins: return [.plugin, .command]
        default: return [.hook]
        }
    }

    private var objectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                LXSidebarSectionHead("\(objects.count)")
                ForEach(objects) { object in
                    LXSidebarRow(object.title, symbol: page.symbol,
                                 isSelected: highlight == object.anchor) {
                        highlight = object.anchor
                    }
                }
            }
            .padding(.bottom, LingXiMetrics.Space.sm)
        }
    }
}
#endif
