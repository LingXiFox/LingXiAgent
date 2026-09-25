#if canImport(SwiftUI)
import SwiftUI

/// ⌘K command palette: app actions plus every command the Application layer
/// registers (the same set the TUI exposes as `/` commands). Low-frequency
/// operations live here instead of as permanent buttons.
struct CommandPalette: View {
    @ObservedObject var runtime: RuntimeFrontend
    var appActions: [PaletteAction]
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("输入命令或操作…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.lxBody)
                    .focused($fieldFocused)
                    .onSubmit { run(at: highlighted) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { onDismiss(); return .handled }
            }
            .padding(LingXiMetrics.Space.lg)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if results.isEmpty {
                            PlaceholderLine("没有匹配的命令。")
                                .padding(LingXiMetrics.Space.lg)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            Button { run(at: index) } label: {
                                HStack(spacing: LingXiMetrics.Space.sm) {
                                    Image(systemName: item.symbol)
                                        .frame(width: LingXiMetrics.Column.eventGlyph)
                                        .foregroundStyle(.secondary)
                                    Text(item.title).font(.lxCallout)
                                    if let detail = item.detail {
                                        Text(detail).font(.lxMeta).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer(minLength: LingXiMetrics.Space.sm)
                                    if let shortcut = item.shortcut {
                                        Text(shortcut).font(.lxMeta.monospaced()).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, LingXiMetrics.Space.md)
                                .frame(minHeight: LingXiMetrics.Row.list)
                                .background(index == highlighted ? Color.accentColor.opacity(0.16) : .clear,
                                            in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                        }
                    }
                    .padding(LingXiMetrics.Space.sm)
                }
                .frame(maxHeight: 360)
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
        }
        .frame(width: 560)
        .lxGlass(in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.surface, style: .continuous))
        .onAppear { fieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("命令面板")
    }

    private var results: [PaletteAction] {
        let commands = runtime.availableCommands.map { command in
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
        let all = appActions + commands
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.detail ?? "").localizedCaseInsensitiveContains(q) }
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
