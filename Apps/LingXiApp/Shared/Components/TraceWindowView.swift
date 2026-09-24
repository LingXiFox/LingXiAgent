#if canImport(SwiftUI)
import SwiftUI

/// 独立运行轨迹窗口 (TraceWindow)
/// 原生 Table 展示执行轨迹事件，支持排序与 JSONL 导出
public struct TraceWindowView: View {
    @ObservedObject public var model: RuntimeInspectorPresentationModel
    @State private var sortOrder = [KeyPathComparator(\TraceEventItemPresentation.timestamp, order: .reverse)]
    @State private var filterKeyword: String = ""

    public init(model: RuntimeInspectorPresentationModel) {
        self.model = model
    }

    public var filteredEvents: [TraceEventItemPresentation] {
        let events = model.traceEvents.isEmpty ? sampleTraceEvents : model.traceEvents
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
        VStack(spacing: 0) {
            // 工具栏：搜索与导出
            HStack(spacing: 12) {
                TextField("按事件类型或模块筛选…", text: $filterKeyword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)

                Spacer()

                Button(action: exportTraceJSONL) {
                    Label("导出 JSONL…", systemImage: "square.and.arrow.up")
                }
            }
            .padding(12)
            .background(LingXiTheme.surfaceBackground)

            Divider()

            // 原生 Table
            Table(filteredEvents, sortOrder: $sortOrder) {
                TableColumn("时间", value: \.timestamp) { event in
                    Text(event.timestamp, style: .time)
                        .font(.system(size: 11, design: .monospaced))
                }
                .width(min: 80, ideal: 90)

                TableColumn("事件类型", value: \.eventType) { event in
                    Text(event.eventType)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .width(min: 140, ideal: 180)

                TableColumn("所属模块", value: \.module) { event in
                    Text(event.module)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(LingXiTheme.secondaryText)
                }
                .width(min: 120, ideal: 140)

                TableColumn("耗时 (ms)", value: \.durationMs) { event in
                    Text("\(event.durationMs) ms")
                        .font(.system(size: 11, design: .monospaced))
                }
                .width(min: 70, ideal: 80)

                TableColumn("状态", value: \.status) { event in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(event.status == "ok" ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(event.status)
                            .font(.system(size: 11))
                    }
                }
                .width(min: 60, ideal: 70)
            }
        }
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

    private var sampleTraceEvents: [TraceEventItemPresentation] {
        [
            TraceEventItemPresentation(timestamp: Date().addingTimeInterval(-10), eventType: "turn.submit", module: "LingXiClient", durationMs: 4, status: "ok"),
            TraceEventItemPresentation(timestamp: Date().addingTimeInterval(-8), eventType: "policy.evaluate", module: "GrantPolicy", durationMs: 1, status: "ok"),
            TraceEventItemPresentation(timestamp: Date().addingTimeInterval(-6), eventType: "token.issue", module: "IssuedToken", durationMs: 2, status: "ok"),
            TraceEventItemPresentation(timestamp: Date().addingTimeInterval(-4), eventType: "tool.dispatch", module: "MCPTransport", durationMs: 120, status: "ok"),
            TraceEventItemPresentation(timestamp: Date().addingTimeInterval(-2), eventType: "stream.delta", module: "LiveDeltaBuffer", durationMs: 38, status: "ok")
        ]
    }
}
#endif
