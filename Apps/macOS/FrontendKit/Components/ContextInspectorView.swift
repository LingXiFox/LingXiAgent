#if os(macOS)
import SwiftUI
import LingXiProtocol

/// The session's P/E runtime inspector: search the current context and open an exact entry.
///
/// §8 puts searchContext and getContextEntry on the right-hand runtime side — they describe what
/// this session is holding right now, not workspace knowledge — and §30 forbids putting them in
/// the persistent 运行上下文 card, which is frozen. So this is a separate window, opened from the
/// same menu as 运行轨迹, and every number it shows is read back from Core rather than mirrored
/// from the sidebar.
struct ContextInspectorView: View {
    @ObservedObject var runtime: RuntimeFrontend
    @State private var query = ""
    @State private var results: [ContextSearchResultItem]?
    @State private var selected: ContextSearchResultItem?
    @State private var entry: ContextEntryItem?
    @State private var error: String?
    @State private var isSearching = false

    var body: some View {
        HStack(spacing: 0) {
            resultsColumn
                .frame(minWidth: 300, idealWidth: 340)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 860, minHeight: 520)
        .task { await runtime.refreshContextInspector() }
        .alert("查询失败", isPresented: Binding(get: { error != nil },
                                               set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Left: search

    private var resultsColumn: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            HStack(spacing: LingXiMetrics.Space.xs) {
                TextField("在当前会话上下文中搜索", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("搜索") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }

            summarySection

            if results == nil {
                Text("搜索范围是本轮会话的上下文条目，不是工作区文件；工作区索引在左侧「代码索引」里。")
                    .font(LXType.meta).foregroundStyle(.secondary)
            } else if results!.isEmpty {
                Text("没有匹配的上下文条目。")
                    .font(LXType.meta).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results!.enumerated()), id: \.offset) { _, item in
                            Button {
                                selected = item
                                Task { await openEntry(item.uri) }
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.uri).font(LXType.meta).lineLimit(1)
                                    Text(item.snippet).font(LXType.meta)
                                        .foregroundStyle(.secondary).lineLimit(3)
                                    Text("匹配度 \(item.score.formatted(.number.precision(.fractionLength(2))))")
                                        .font(LXType.meta).foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(selected?.uri == item.uri
                                            ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(LingXiMetrics.Space.md)
    }

    /// P/E usage and the effective policy, in words a person can act on. Compact is the one
    /// mutation here and it goes through the RPC, then re-reads.
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let live = runtime.inspectorModel.live {
                metricRow("P-Core", live.context?.pCore.map {
                    "\($0.usedTokens) / \($0.targetTokens) tokens"
                } ?? "—")
                metricRow("E-Core", live.context?.eCore.map {
                    "\($0.objectCount) 对象 · \(TokenFormatter.formatBytes($0.totalBytes))"
                } ?? "—")
                metricRow("Provider 缓存", live.context?.providerCache.map {
                    "读 \($0.cacheReadTokens) / 提示 \($0.promptTokens)"
                } ?? "—")
            }
            if let policy = runtime.inspectorModel.effectivePolicy {
                metricRow("生效策略", "模型窗口 \(policy.modelWindow) · P 目标 \(policy.pCoreTarget) / 硬限 \(policy.pCoreHardLimit)")
                metricRow("E-Core 预算", "存储 \(policy.eCoreStorageBudget) · 召回 \(policy.eCoreRecallBudget) · 压力阈值 \(policy.eCorePressureThreshold)")
            }
            performanceSection

            HStack(spacing: LingXiMetrics.Space.sm) {
                Button("刷新") {
                    Task {
                        await runtime.refreshContextInspector()
                        await runtime.loadPerformanceReport()
                    }
                }
                Button("压缩上下文") {
                    Task { await runtime.compactCurrentContext() }
                }
                .disabled(runtime.conversationModel.isGenerating)
            }
            .font(LXType.meta)
            .padding(.top, 2)
        }
        .padding(.vertical, LingXiMetrics.Space.xs)
    }

    /// §10.1. Turn latency, tool time and context budget, from the profiler Core writes — not
    /// the global ProviderMetrics zeros that used to be shown, which are now unsupported.
    @ViewBuilder private var performanceSection: some View {
        if let report = runtime.inspectorModel.performance {
            VStack(alignment: .leading, spacing: 3) {
                LXHairline()
                metricRow("本轮总耗时", "\(Int(report.totalMilliseconds)) ms · \(report.stepCount) 步")
                metricRow("首个文本", report.firstTextMilliseconds.map { "\(Int($0)) ms" } ?? "—")
                metricRow("Core 开销", "\(Int(report.coreOverheadMilliseconds)) ms")
                if !report.tools.isEmpty {
                    let toolTotal = report.tools.reduce(0.0) { $0 + $1.executionMilliseconds }
                    metricRow("工具时间", "\(Int(toolTotal)) ms / \(report.tools.count) 次")
                    ForEach(report.tools.prefix(4), id: \.step) { tool in
                        HStack(spacing: LingXiMetrics.Space.xs) {
                            Text("步骤 \(tool.step) · \(tool.toolName)")
                            Spacer(minLength: 0)
                            Text("\(Int(tool.executionMilliseconds)) ms")
                        }
                        .font(LXType.meta).foregroundStyle(.secondary)
                    }
                }
                if let budget = report.contextBudget {
                    metricRow("上下文预算", "模型窗口 \(budget.modelWindow) · 硬限 \(budget.hardInputLimit) · 首选活跃 \(budget.preferredActive)")
                }
                metricRow("压缩次数", "\(report.compactions.count)")
            }
        } else {
            Text("尚无本轮性能数据（Core 还没跑过带剖析的回合）。")
                .font(LXType.meta).foregroundStyle(.secondary)
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: LingXiMetrics.Space.xs) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: LingXiMetrics.Space.md)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(LXType.meta)
    }

    // MARK: - Right: the opened entry

    private var detailColumn: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                        Text(entry.uri)
                            .font(LXType.body.weight(.semibold))
                            .textSelection(.enabled)
                        LXHairline()
                        Text(entry.content)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(LingXiMetrics.Space.md)
                }
            } else {
                VStack(spacing: LingXiMetrics.Space.sm) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: LXIcon.emptyState))
                    Text(selected == nil ? "选择一条搜索结果，这里显示它的完整条目。"
                                         : "正在从 Core 读取该条目…")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        isSearching = true
        Task {
            do {
                results = try await runtime.searchCurrentContext(term)
                error = nil
            } catch {
                self.error = error.localizedDescription
                results = []
            }
            isSearching = false
        }
    }

    private func openEntry(_ uri: String) async {
        entry = nil
        do {
            entry = try await runtime.contextEntry(uri: uri)
        } catch {
            self.error = "无法打开该上下文条目：\(error.localizedDescription)"
        }
    }
}
#endif
