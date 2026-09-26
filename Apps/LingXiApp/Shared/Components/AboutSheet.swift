#if canImport(SwiftUI)
import SwiftUI

/// About: one of the two places `display` 28/34 may appear. The mark is the
/// stand-in until the real logo lands. Every value comes from the bundle or the
/// runtime; nothing is written in.
public struct AboutSheet: View {
    @ObservedObject var runtime: RuntimeFrontend
    @Environment(\.dismiss) private var dismiss

    public init(runtime: RuntimeFrontend) { self.runtime = runtime }

    public var body: some View {
        VStack(spacing: LingXiMetrics.Space.xl) {
            VStack(spacing: LingXiMetrics.Space.lg) {
                LXBrandMark()
                VStack(spacing: LingXiMetrics.Space.xs) {
                    Text("灵犀 LingXi").font(LXType.display).accessibilityAddTraits(.isHeader)
                    Text("macOS 原生的本地 AI 工作台").font(LXType.meta).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                LXKVRow("版本", value: version)
                LXKVRow("架构", value: architecture)
                LXKVRow("Core", value: LXStatusText(runtime.link == .connected ? "已连接" : "未连接",
                                                    systemImage: runtime.link == .connected ? "checkmark.circle" : "circle",
                                                    tone: runtime.link == .connected ? .success : .muted))
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.lxPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(LingXiMetrics.Space.xxl)
        .frame(width: 420)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "开发版本"
        }
    }

    private var architecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }
}
#endif
