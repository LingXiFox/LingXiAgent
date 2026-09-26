#if canImport(SwiftUI)
import SwiftUI

/// ⌘K command palette: app actions plus every command the Application layer
/// registers (the same set the TUI exposes as `/` commands). Low-frequency
/// operations live here instead of as permanent buttons.
///
/// Visual contract (§4 / §6): a temporary floating surface — untinted Liquid
/// Glass, 1px separator ring, shadow-float, radius `surface` 20, padding 16.
/// The suggestion list is part of that SAME glass layer inside one
/// `LXGlassGroup`, so palette and list read as one surface and morph together
/// instead of stacking a card inside a card.
///
/// Rows follow the §7 menu geometry: 28pt tall, radius-sm 6, body 13/18, icons
/// and kbd hints neutral, and the highlighted row takes the accent fill a macOS
/// menu uses — which makes it the only accent fill on this surface.
struct CommandPalette: View {
    @ObservedObject var runtime: RuntimeFrontend
    var appActions: [PaletteAction]
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool
    @Namespace private var glassSpace

    /// §7 menu metrics. 14 is an icon side, not a spacing step; the 5×10
    /// separator margin and the 10pt row trailing inset are the menu values the
    /// spec states verbatim, kept in one place instead of scattered.
    private enum Menu {
        static let glyph: CGFloat = 14
        static let rowLeading: CGFloat = LingXiMetrics.Space.sm
        static let rowTrailing: CGFloat = 10
        static let gap: CGFloat = LingXiMetrics.Space.sm
        static let separatorMarginX: CGFloat = 10
        static let separatorMarginY: CGFloat = 5
        /// Heads align with the label column: leading + glyph + gap = 30.
        static var headIndent: CGFloat { rowLeading + glyph + gap }
    }

    var body: some View {
        LXGlassGroup(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                searchField
                headSeparator
                suggestions
            }
            .frame(width: LingXiMetrics.Column.palette)
            .lxFloating()
            .lxGlassID("palette", in: glassSpace)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("命令面板")
    }

    // MARK: - Layers

    private var searchField: some View {
        HStack(spacing: Menu.gap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Menu.glyph))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("输入命令或操作…", text: $query)
                .textFieldStyle(.plain)
                .font(LXType.body)
                .focused($fieldFocused)
                .onSubmit { run(at: highlighted) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }
        }
        .padding(LingXiMetrics.Space.lg)
    }

    /// 1px hairline between the field and the list — a seam, not a card edge.
    private var headSeparator: some View {
        Rectangle()
            .fill(LXColor.separator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var suggestions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        PlaceholderLine("没有匹配的命令。")
                            .padding(LingXiMetrics.Space.md)
                    }
                    ForEach(Array(sections.enumerated()), id: \.element.id) { order, section in
                        if order > 0 { sectionSeparator }
                        LXSectionHead(section.title)
                            .padding(.leading, Menu.headIndent)
                            .padding(.trailing, Menu.separatorMarginX)
                            .padding(.top, LingXiMetrics.Space.xs)
                            .padding(.bottom, LingXiMetrics.Space.xs)
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                            row(item, index: section.startIndex + offset)
                        }
                    }
                }
                .padding(.horizontal, LingXiMetrics.Space.xs)
                .padding(.vertical, LingXiMetrics.Space.xs)
            }
            .frame(maxHeight: 400)
            .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
        }
    }

    private var sectionSeparator: some View {
        Rectangle()
            .fill(LXColor.separator)
            .frame(height: 1)
            .padding(.vertical, Menu.separatorMarginY)
            .padding(.horizontal, Menu.separatorMarginX)
            .accessibilityHidden(true)
    }

    private func row(_ item: PaletteAction, index: Int) -> some View {
        let isSelected = index == highlighted
        return Button { run(at: index) } label: {
            HStack(spacing: Menu.gap) {
                Image(systemName: item.symbol)
                    .font(.system(size: Menu.glyph))
                    .frame(width: Menu.glyph)
                    .foregroundStyle(isSelected ? AnyShapeStyle(LXColor.onAccent) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(LXType.body)
                    .foregroundStyle(isSelected ? AnyShapeStyle(LXColor.onAccent) : AnyShapeStyle(.primary))
                if let detail = item.detail {
                    Text(detail)
                        .font(LXType.meta)
                        .foregroundStyle(isSelected ? AnyShapeStyle(LXColor.onAccent.opacity(0.8))
                                                     : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: Menu.gap)
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(LXType.meta.monospaced())
                        .foregroundStyle(isSelected ? AnyShapeStyle(LXColor.onAccent.opacity(0.8))
                                                     : AnyShapeStyle(.secondary))
                }
            }
            .padding(.leading, Menu.rowLeading)
            .padding(.trailing, Menu.rowTrailing)
            .frame(height: LingXiMetrics.Size.menuItem)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? LXColor.accent : .clear,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Data

    /// One flat, ordered match list; sections only split it for presentation, so
    /// index-based keyboard navigation and `run(at:)` keep their meaning.
    private var results: [PaletteAction] { matching(appActions) + matching(runtimeCommands) }

    private struct Section {
        let id: String
        let title: String
        let startIndex: Int
        let items: [PaletteAction]
    }

    private var sections: [Section] {
        var built: [Section] = []
        var offset = 0
        let candidates: [(id: String, title: String, items: [PaletteAction])] = [
            ("app", "操作", matching(appActions)),
            ("command", "命令", matching(runtimeCommands)),
        ]
        for candidate in candidates where !candidate.items.isEmpty {
            built.append(Section(id: candidate.id, title: candidate.title,
                                 startIndex: offset, items: candidate.items))
            offset += candidate.items.count
        }
        return built
    }

    private var runtimeCommands: [PaletteAction] {
        runtime.availableCommands.map { command in
            PaletteAction(id: "cmd.\(command.name)", title: "/\(command.name)", detail: command.summary,
                          symbol: "chevron.left.forwardslash.chevron.right", shortcut: nil,
                          needsArgument: !command.argument.isEmpty && command.argument.contains("<")) {
                if !command.argument.isEmpty && command.argument.contains("<") {
                    runtime.composerModel.text = "/\(command.name) "
                } else {
                    runtime.runCommand("/\(command.name)")
                }
            }
        }
    }

    private func matching(_ items: [PaletteAction]) -> [PaletteAction] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.detail ?? "").localizedCaseInsensitiveContains(q) }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }

    private func run(at index: Int) {
        guard results.indices.contains(index) else { return }
        let action = results[index]
        onDismiss()
        action.perform()
    }
}

struct PaletteAction: Identifiable {
    let id: String
    let title: String
    var detail: String?
    var symbol: String
    var shortcut: String?
    var needsArgument = false
    let perform: () -> Void
}

#endif
