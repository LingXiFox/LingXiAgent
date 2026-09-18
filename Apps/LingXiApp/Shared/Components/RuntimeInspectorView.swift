import SwiftUI

public struct RuntimeInspectorView: View {
    @ObservedObject public var model: RuntimeInspectorPresentationModel

    public init(model: RuntimeInspectorPresentationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Text("RUNTIME INSPECTOR")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(LingXiGlass.Palette.textSecondary)
                Spacer()
                Circle()
                    .fill(LingXiGlass.Palette.statusSuccess)
                    .frame(width: 6, height: 6)
            }
            .padding(.bottom, 4)

            // P-Core Codebase Graph
            telemetryCard(title: "P-CORE GRAPH", symbol: "point.3.connected.trianglepath.dotted") {
                VStack(spacing: 4) {
                    HStack {
                        Text("Nodes")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                        Spacer()
                        Text("\(model.telemetry.pcoreNodes)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(LingXiGlass.Palette.textPrimary)
                    }
                    HStack {
                        Text("Edges")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                        Spacer()
                        Text("\(model.telemetry.pcoreEdges)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(LingXiGlass.Palette.textPrimary)
                    }
                }
            }

            // E-Core Episodic Heat
            telemetryCard(title: "E-CORE HEAT", symbol: "flame.fill") {
                VStack(spacing: 6) {
                    HStack {
                        Text("Thermal Index")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                        Spacer()
                        Text(String(format: "%.0f%%", model.telemetry.ecoreHeat * 100))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(model.telemetry.ecoreHeat > 0.8 ? LingXiGlass.Palette.statusWarning : LingXiGlass.Palette.matrixGreen)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [LingXiGlass.Palette.cyberCyan, LingXiGlass.Palette.foxOrange],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * CGFloat(model.telemetry.ecoreHeat))
                        }
                    }
                    .frame(height: 6)
                }
            }

            // Provider Cache & Throughput
            telemetryCard(title: "PROVIDER & CACHE", symbol: "bolt.horizontal.fill") {
                VStack(spacing: 6) {
                    HStack {
                        Text("Cache Hit Ratio")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                        Spacer()
                        Text(String(format: "%.1f%%", model.telemetry.cacheHitRatio * 100))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(LingXiGlass.Palette.cyberCyan)
                    }
                    HStack {
                        Text("Throughput")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                        Spacer()
                        Text(String(format: "%.1f t/s", model.telemetry.tokensPerSecond))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(LingXiGlass.Palette.textPrimary)
                    }
                }
            }

            // Services & Status
            telemetryCard(title: "SERVICES", symbol: "server.rack") {
                VStack(spacing: 6) {
                    HStack {
                        Text("Retrieval Index")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                        Spacer()
                        Text(model.telemetry.retrievalWarmup.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(LingXiGlass.Palette.statusSuccess)
                    }
                    HStack {
                        Text("Active MCP")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                        Spacer()
                        Text("\(model.telemetry.activeMCPCount)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(LingXiGlass.Palette.textPrimary)
                    }
                    HStack {
                        Text("Background Tasks")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                        Spacer()
                        Text("\(model.telemetry.activeBackgroundTasks)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(model.telemetry.activeBackgroundTasks > 0 ? LingXiGlass.Palette.foxOrange : LingXiGlass.Palette.textTertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .frame(minWidth: 230, idealWidth: 260)
        .lingXiGlass(tier: .panel, cornerRadius: 0)
    }

    @ViewBuilder
    private func telemetryCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundColor(LingXiGlass.Palette.cyberCyan)
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(LingXiGlass.Palette.textSecondary)
            }
            content()
        }
        .padding(10)
        .lingXiGlass(tier: .card, cornerRadius: 8)
    }
}
