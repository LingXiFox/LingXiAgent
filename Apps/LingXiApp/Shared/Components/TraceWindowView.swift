#if canImport(SwiftUI)
import SwiftUI

/// 独立运行轨迹窗口 (TraceWindow)
/// 原生 Table 展示执行轨迹事件，支持排序与 JSONL 导出
///
/// 视觉契约（§2 / §4）：诊断视图保持结构化可读 —— 原始负载用 mono-sm 12.5、
/// 标签恒为 text-primary，状态色只着色 6pt 圆点；控制条是 fill-quinary +
/// radius-inset 内嵌块。这一层不是浮层：无玻璃、无阴影、无氛围光。
public struct TraceWindowView: View {
    @ObservedObject public var model: RuntimeInspectorPresentationModel
    @State private var sortOrder = [KeyPathComparator(\TraceEventItemPresentation.timestamp, order: .reverse)]
    @State private var filterKeyword: String = ""

    public init(model: RuntimeInspectorPresentationModel) {
        self.model = model
    }

    public var filteredEvents: [TraceEventItemPresentation] {
        let events = model.traceEvents
        if filterKeyword.isEmpty {
            return events.sorted(using: sortOrder)
        } else {
            return events.filter {
                $0.eventType.localizedCaseInsensitiveContains(filterKeyword) ||
                $0.module.localizedCaseInsensitiveContains(filterKeyword)
            }.sorted(using: sortOrder)
        }
    }

    public var body: some View {
        VStack(spacing: LingXiMetrics.Space.sm) {
            // 工具栏：搜索与导出。控制条是内嵌块（fill-quinary + radius-inset），
            // 不是卡片：无描边、无阴影、无玻璃。
            HStack(spacing: LingXiMetrics.Space.md) {
                TextField("按事件类型或模块筛选…", text: $filterKeyword)
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

                TableColumn("事件类型", value: \.eventType) { event in
                    Text(event.eventType)
                        .font(LXType.monoSmall)
                        .foregroundStyle(.primary)
                }
                .width(min: 160, ideal: 200)

                TableColumn("所属模块", value: \.module) { event in
                    Text(event.module)
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)

                TableColumn("耗时 (ms)", value: \.durationMs) { event in
                    Text("\(event.durationMs) ms")
                        .font(LXType.meta)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .width(min: 80, ideal: 96)

                // 状态：颜色只落在 6pt 圆点上，文字恒为 text-primary。
                TableColumn("状态", value: \.status) { event in
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Circle()
                            .fill(event.status == "ok" ? LXStatus.success : LXStatus.error)
                            .frame(width: LXControl.dot, height: LXControl.dot)
                        Text(event.status)
                            .font(LXType.meta)
                            .foregroundStyle(.primary)
                    }
                }
                .width(min: 70, ideal: 84)
            }
        }
        .overlay {
            if model.traceEvents.isEmpty {
                ContentUnavailableView("运行轨迹暂不可用", systemImage: "list.bullet.rectangle",
                                       description: Text("Core 还没有实现 getRunTrace 的 spans，"
                                                       + "本会话的执行事件不会写入这里。"))
            }
        }
        .background(LXColor.content)
        .frame(minWidth: 640, minHeight: 400)
    }

    private func exportTraceJSONL() {
        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "lingxi-trace-\(Date().timeIntervalSince1970).jsonl"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            let lines = filteredEvents.map {
                "{\"timestamp\":\"\($0.timestamp)\",\"type\":\"\($0.eventType)\",\"module\":\"\($0.module)\",\"duration\":\($0.durationMs),\"status\":\"\($0.status)\"}"
            }.joined(separator: "\n")
            try? lines.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }
}
#endif
