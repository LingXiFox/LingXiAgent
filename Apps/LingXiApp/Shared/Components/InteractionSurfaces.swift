#if canImport(SwiftUI)
import SwiftUI

// MARK: - Permission

/// Temporary approval layer: tool, verbatim command, queue position, requester
/// run and current policy, then Deny / Allow. The panel stays neutral; Fox
/// lands on the head icon and the Allow button only (warning shield when the
/// request is elevated). Esc is not bound: it must never resolve a request.
struct PermissionSurface: View {
    let card: InteractionCardPresentation
    let position: String
    let policy: String
    let onResolve: (Bool) -> Void

    private var isElevated: Bool {
        LXToolGlyph.isElevated(card.toolName)
            || card.capabilities.contains { $0.localizedCaseInsensitiveContains("external")
                || $0.localizedCaseInsensitiveContains("sensitive") }
    }

    var body: some View {
        LXFloatingSurface {
            LXSurfaceHead(symbol: isElevated ? "exclamationmark.shield.fill" : "checkmark.shield",
                          tint: isElevated ? LXStatus.warning : LXColor.accentText,
                          title: "请求授权") {
                LXBadge(card.toolName, systemImage: LXToolGlyph.symbol(for: card.toolName))
            }

            Text("第 \(position) 项 · 发起方 \(card.agentRunID)")
                .font(LXType.meta)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !card.parametersSummary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(card.resource.isEmpty ? "待执行命令 / 参数" : "目标 \(card.resource)")
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: LingXiMetrics.Space.sm)
                        LXCopyButton(card.parametersSummary, label: "复制命令")
                    }
                    Text(card.parametersSummary)
                        .font(LXType.mono)
                        .lineSpacing(LXType.Leading.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lxInsetBlock()
                }
            }

            Text("当前策略：\(policy)")
                .font(LXType.meta)
                .foregroundStyle(.secondary)

            HStack(spacing: LingXiMetrics.Space.sm) {
                Spacer(minLength: 0)
                Button("拒绝") { onResolve(false) }
                    .buttonStyle(.lxSecondary)
                Button { onResolve(true) } label: { LXKeyHintLabel("允许", hint: "⏎") }
                    .buttonStyle(.lxPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: LingXiMetrics.Column.surface, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("权限审批：\(card.toolName)")
        .accessibilityAction(named: "允许一次") { onResolve(true) }
        .accessibilityAction(named: "拒绝") { onResolve(false) }
    }
}

// MARK: - Question

/// Structured question or decision: options (single or multi), optional note,
/// Cancel (Esc) / Submit (⏎). Selected rows take accent-soft, marks the accent fill.
struct QuestionSurface: View {
    let card: InteractionCardPresentation
    let position: String
    let onSubmit: ([Int], String?) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<Int> = []
    @State private var note = ""

    private var canSubmit: Bool {
        !selected.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        LXFloatingSurface {
            LXSurfaceHead(symbol: card.kind == .decision ? "arrow.triangle.branch" : "questionmark.bubble",
                          title: card.kind == .decision ? "需要你决定" : "Agent 提问") {
                Text(position).font(LXType.meta).foregroundStyle(.secondary)
            }

            Text(card.parametersSummary)
                .font(LXType.editor)
                .lineSpacing(LXType.Leading.editor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !card.options.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                        OptionRow(title: option, isOn: selected.contains(index), isRadio: !card.allowsMultiple) {
                            toggle(index)
                        }
                    }
                }
            }

            if card.allowsFreeText || card.options.isEmpty {
                TextField(card.options.isEmpty ? "你的回答" : "补充说明（可选）", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(LXType.body)
                    .lineLimit(1...4)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(LXColor.content,
                                in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control, style: .continuous))
                    .lxRing(cornerRadius: LingXiMetrics.Radius.control)
            }

            HStack(spacing: LingXiMetrics.Space.sm) {
                Spacer(minLength: 0)
                Button("取消", action: onCancel)
                    .buttonStyle(.lxSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(selected.sorted(), trimmed.isEmpty ? nil : trimmed)
                } label: { LXKeyHintLabel("提交", hint: "⏎") }
                    .buttonStyle(.lxPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .frame(maxWidth: LingXiMetrics.Column.surface, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent 提问：\(card.parametersSummary)")
    }

    private func toggle(_ index: Int) {
        if card.allowsMultiple {
            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
        } else {
            selected = selected.contains(index) ? [] : [index]
        }
    }
}

private struct OptionRow: View {
    let title: String
    let isOn: Bool
    let isRadio: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                mark
                Text(title)
                    .font(LXType.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .background(isOn ? LXColor.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// 16pt mark: 1.5pt text-secondary ring when off, accent fill + glyph when on.
    private var mark: some View {
        let shape = isRadio ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        return ZStack {
            if isOn {
                shape.fill(LXColor.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(LXColor.onAccent)
            } else {
                shape.stroke(Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: LXControl.optionMark, height: LXControl.optionMark)
        .accessibilityHidden(true)
    }
}
#endif
