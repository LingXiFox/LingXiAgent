#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

private struct TraceRow: Identifiable {
    let raw: RuntimeTraceEvent
    var id: String { raw.traceID }
    var timestamp: Date { raw.timestamp }
    var event: String { raw.event }
    var kind: RuntimeTraceKind { raw.kind }
    var runID: AgentRunID? { raw.runID }
    var durationMicroseconds: Int64? { raw.durationMicroseconds }
    var errorCode: String? { raw.errorCode }
}

/// 独立运行轨迹窗口 (TraceWindow)
/// 原生 Table 展示执行轨迹事件，支持排序与 JSONL 导出
///
/// 视觉契约（§2 / §4）：诊断视图保持结构化可读 —— 原始负载用 mono-sm 12.5、
/// 标签恒为 text-primary，状态色只着色 6pt 圆点；控制条是 fill-quinary +
/// radius-inset 内嵌块。这一层不是浮层：无玻璃、无阴影、无氛围光。
public struct TraceWindowView: View {
    @ObservedObject public var model: RuntimeInspectorPresentationModel
    public let onRefresh: () async -> Void
    @State private var sortOrder = [KeyPathComparator(\TraceRow.timestamp, order: .reverse)]
    @State private var filterKeyword: String = ""
    @State private var exportError = ""
    @State private var showsExportError = false

    public init(model: RuntimeInspectorPresentationModel, onRefresh: @escaping () async -> Void) {
        self.model = model
        self.onRefresh = onRefresh
    }

    private var filteredEvents: [TraceRow] {
        let events = model.traceEvents.map(TraceRow.init)
        if filterKeyword.isEmpty {
            return events.sorted(using: sortOrder)
        } else {
            return events.filter {
                $0.event.localizedCaseInsensitiveContains(filterKeyword) ||
                $0.kind.rawValue.localizedCaseInsensitiveContains(filterKeyword) ||
                ($0.runID?.rawValue.localizedCaseInsensitiveContains(filterKeyword) ?? false)
            }.sorted(using: sortOrder)
        }
    }

    public var body: some View {
        VStack(spacing: LingXiMetrics.Space.sm) {
            // 工具栏：搜索与导出。控制条是内嵌块（fill-quinary + radius-inset），
            // 不是卡片：无描边、无阴影、无玻璃。
            HStack(spacing: LingXiMetrics.Space.md) {
                TextField("按事件、类别或 AgentRun 筛选…", text: $filterKeyword)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(LXType.body)
                    .frame(maxWidth: 280)

                Spacer(minLength: LingXiMetrics.Space.md)

                Button(action: exportTraceJSONL) {
                    Label("导出 JSONL…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.large)
            }
            .lxInsetBlock()
            .padding(LingXiMetrics.Space.md)

            // 原生 Table
            Table(filteredEvents, sortOrder: $sortOrder) {
                TableColumn("时间", value: \.timestamp) { event in
                    Text(event.timestamp, style: .time)
                        .font(LXType.monoSmall)
                        .foregroundStyle(.primary)
                }
                .width(min: 90, ideal: 110)

                TableColumn("事件", value: \.event) { event in
                    Text(event.event)
                        .font(LXType.monoSmall)
                        .foregroundStyle(.primary)
                }
                .width(min: 160, ideal: 200)

                TableColumn("AgentRun") { event in
                    Text(event.runID?.rawValue ?? "—")
                        .font(LXType.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 110, ideal: 150)

                TableColumn("类别") { event in
                    Text(event.kind.rawValue)
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)

                TableColumn("耗时") { event in
                    Text(event.durationMicroseconds.map { "\($0 / 1_000) ms" } ?? "—")
                        .font(LXType.meta)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .width(min: 80, ideal: 96)

                // 状态：颜色只落在 6pt 圆点上，文字恒为 text-primary。
                TableColumn("状态") { event in
                    let failed = event.errorCode != nil || event.kind == .error
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Circle()
                            .fill(failed ? LXStatus.error : LXStatus.success)
                            .frame(width: LXControl.dot, height: LXControl.dot)
                        Text(failed ? "错误" : "正常")
                            .font(LXType.meta)
                            .foregroundStyle(.primary)
                    }
                }
                .width(min: 70, ideal: 84)
            }
        }
        .overlay {
            if model.traceEvents.isEmpty {
                ContentUnavailableView("暂无运行轨迹", systemImage: "list.bullet.rectangle",
                                       description: Text("Core 尚未记录诊断事件。"))
            }
        }
        .background(LXColor.content)
        .frame(minWidth: 760, minHeight: 400)
        .task {
            while !Task.isCancelled {
                await onRefresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .alert("导出失败", isPresented: $showsExportError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError)
        }
    }

    private func exportTraceJSONL() {
        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "lingxi-trace-\(Date().timeIntervalSince1970).jsonl"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try Self.jsonl(filteredEvents.map(\.raw)).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = error.localizedDescription
                showsExportError = true
            }
        }
        #endif
    }

    static func jsonl(_ events: [RuntimeTraceEvent]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
    }
}
#endif
