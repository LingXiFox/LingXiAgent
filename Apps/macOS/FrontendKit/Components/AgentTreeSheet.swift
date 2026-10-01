#if os(macOS)
import SwiftUI
import LingXiProtocol

/// The full Agent tree, opened from the compact 子代理状态 block.
///
/// Core owns the shape: this renders `getAgentTree` as returned and issues `cancelRun` /
/// `resumeRun` against the run IDs in it, then re-reads the tree. Nothing here reconstructs
/// parentage from the timeline — a locally-guessed tree is the "GUI maintains authoritative
/// runtime state" case the closure contract forbids.
struct AgentTreeSheet: View {
    @ObservedObject var runtime: RuntimeFrontend
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Text("Agent 树").font(LXType.title)
                Spacer()
                Button {
                    Task { await runtime.refreshAgentTree() }
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(LingXiMetrics.Space.lg)
            LXHairline()

            if runtime.agentTree == nil {
                VStack(spacing: LingXiMetrics.Space.sm) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: LXIcon.emptyState))
                    Text("Core 没有返回 Agent 树")
                    Text("会话可能尚未创建任何 Run。").font(LXType.meta)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let root = runtime.agentTree {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AgentTreeRow(node: root, depth: 0, runtime: runtime)
                    }
                    .padding(LingXiMetrics.Space.md)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .task { await runtime.refreshAgentTree() }
        .alert("操作未完成", isPresented: Binding(get: { runtime.actionError != nil },
                                                 set: { if !$0 { runtime.actionError = nil } })) {
            Button("好") { runtime.actionError = nil }
        } message: {
            Text(runtime.actionError ?? "")
        }
    }
}

/// One node and its children. Recursion in a view is done through a subview, not a closure,
/// so SwiftUI can identify each level.
private struct AgentTreeRow: View {
    let node: AgentTreeNode
    let depth: Int
    @ObservedObject var runtime: RuntimeFrontend

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            ForEach(node.children, id: \.session.id) { child in
                AgentTreeRow(node: child, depth: depth + 1, runtime: runtime)
            }
        }
    }

    @ViewBuilder private var row: some View {
        let run = node.latestRun
        HStack(spacing: LingXiMetrics.Space.xs) {
            ForEach(0..<depth, id: \.self) { _ in
                Color.clear.frame(width: LingXiMetrics.Space.lg)
            }
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(run?.title ?? node.session.title ?? "会话 \(node.session.id.rawValue)")
                    .font(LXType.body).lineLimit(1)
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(run.map { $0.status.rawValue } ?? "无 Run").font(LXType.meta)
                    if let model = run?.modelSelection.modelID {
                        Text(model).font(LXType.meta).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(shortID(run?.runID.rawValue)).font(LXType.meta).foregroundStyle(.tertiary)
                    if let started = run?.startedAt {
                        Text("起 \(Self.time.string(from: started))").font(LXType.meta)
                            .foregroundStyle(.tertiary)
                    }
                    Text("活 \(Self.time.string(from: run?.latestActivityAt ?? node.session.updatedAt))")
                        .font(LXType.meta).foregroundStyle(.tertiary)
                    if let reason = run?.terminalReason {
                        Text("终止：\(reason.rawValue)").font(LXType.meta).foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: LingXiMetrics.Space.sm)

            if let run {
                    let id = RunID(run.runID.rawValue)
                if run.status == .running || run.status == .queued || run.status == .starting
                    || run.status == .waitingForTool || run.status == .waitingForUser {
                    Button("取消") {
                        Task { await runtime.cancelAgentRun(id, title: run.title) }
                    }
                }
                // Only a non-terminal run offers Resume; Core rejects terminal ones outright now,
                // so an enabled button on a finished run would be decoration.
                if run.status == .recoveryRequired || run.status == .failed {
                    Button("恢复") {
                        Task { await runtime.resumeAgentRun(id, title: run.title) }
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.trailing, LingXiMetrics.Space.sm)
    }

    private func shortID(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        return String(raw.prefix(8))
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
#endif
