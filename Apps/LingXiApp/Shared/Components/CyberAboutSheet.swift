#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

/// Cyber-styled About Sheet for LingXi Agent
public struct CyberAboutSheet: View {
    @ObservedObject public var runtime: RuntimeFrontend
    @Environment(\.dismiss) private var dismiss

    public init(runtime: RuntimeFrontend) {
        self.runtime = runtime
    }

    public var body: some View {
        VStack(spacing: LingXiMetrics.Space.lg) {
            // Foxfire Cyber Emblem Header
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                LingXiTheme.foxfireAmber.opacity(0.4),
                                LingXiTheme.astralViolet.opacity(0.2),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)

                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [LingXiTheme.foxfireAmber, LingXiTheme.electricCyan.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 88, height: 88)

                Image(systemName: "flame.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [LingXiTheme.foxfireAmber, LingXiTheme.solarGold, LingXiTheme.neonCoral],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .lxNeonGlow(color: LingXiTheme.foxfireAmber, radius: 12, opacity: 0.8)
            }
            .padding(.top, LingXiMetrics.Space.md)

            VStack(spacing: 4) {
                Text("LingXi Agent")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, LingXiTheme.electricCyan.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("灵犀 · 主人的赛博智能体伴写小狐狸")
                    .font(.lxCallout.weight(.medium))
                    .foregroundStyle(LingXiTheme.foxfireAmber)
            }

            // Specs Bento Grid
            VStack(spacing: LingXiMetrics.Space.xs) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    AboutSpecCell(label: "应用版本", value: "v1.0.0 (Release 1)")
                    AboutSpecCell(label: "内核协议", value: "vNext Wire 1.1")
                }
                HStack(spacing: LingXiMetrics.Space.xs) {
                    AboutSpecCell(label: "运行架构", value: "Apple Silicon arm64")
                    AboutSpecCell(label: "运行时状态", value: runtime.link == .connected ? "Core 已接入" : "未连接")
                }
            }
            .frame(maxWidth: 380)

            VStack(spacing: 4) {
                Text("以认真查询为荣，以遵循规范为荣。")
                    .font(.lxMeta)
                    .foregroundStyle(.secondary)
                Text("Crafted with passion in Cyber Space for 主人.")
                    .font(.lxMicro)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, LingXiMetrics.Space.xs)

            Button("关闭") {
                dismiss()
            }
            .lxPrimaryButtonStyle()
            .buttonBorderShape(.capsule)
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, LingXiMetrics.Space.sm)
        }
        .padding(LingXiMetrics.Space.xl)
        .frame(width: 440)
        .background(
            ZStack {
                AtmosphereBackdrop()
                Color.black.opacity(0.65)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .lxCrystalBorder(cornerRadius: 20, glowColor: LingXiTheme.foxfireAmber, glowRadius: 16)
    }
}

private struct AboutSpecCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.lxMicro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.lxMeta.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LingXiMetrics.Space.md)
        .padding(.vertical, LingXiMetrics.Space.sm)
        .lxGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                 tint: LingXiTheme.obsidianSurface.opacity(0.7))
        .lxCrystalBorder(cornerRadius: 10)
    }
}
#endif
