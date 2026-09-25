import SwiftUI

/// 运行模式：工作区正常华丽模式 vs 设置克制模式
public enum AtmosphereMode: Sendable, Equatable {
    case workspace
    case settings
}

/// 赛博深空极光背景：连续环境光场 ✕ 蓝紫青橙温度平衡
///
/// 视觉设计标准：
/// - 主光源 A：Indigo / Cold Blue，中左偏上，超大弥散范围（覆盖大部分窗口）
/// - 主光源 B：Teal / Cyan，右下方，大弥散范围
/// - 辅助光：Fox Orange / Amber，极低透明度，偏左下方，仅负责冷暖温度平衡
/// - 无独立 Violet 灯（由 Indigo 与周围色彩重叠自然生成过渡紫韵）
/// - 无硬切水平/垂直直线，呈一体化深空极光漫射
/// - 纯矢量静态渲染，空闲时零持续刷新与零 GPU 循环占用
public struct AtmosphereBackdrop: View {
    public var mode: AtmosphereMode = .workspace
    @AppStorage(LXPreferenceKey.atmosphere) private var preference = AtmospherePreference.subtle
    @Environment(\.colorScheme) private var colorScheme

    public init(mode: AtmosphereMode = .workspace) {
        self.mode = mode
    }

    private var modeStrength: Double {
        switch mode {
        case .workspace: return 1.0
        case .settings: return 0.40
        }
    }

    public var body: some View {
        ZStack {
            // 深邃暗夜黑曜石底色
            LingXiTheme.deepNightBackground

            if preference != .off {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let span = max(w, h)

                    ZStack {
                        // 1. 主光源 A：深空星云冷靛蓝（覆盖全场偏左上）
                        glow(
                            LingXiTheme.atmosphereIndigo,
                            0.45,
                            center: UnitPoint(x: 0.15, y: 0.22),
                            radius: span * 0.90,
                            size: geo.size
                        )

                        // 2. 主光源 B：电光青绿脉冲（右下方大面积漫射）
                        glow(
                            LingXiTheme.atmosphereTeal,
                            0.35,
                            center: UnitPoint(x: 0.88, y: 0.82),
                            radius: span * 0.85,
                            size: geo.size
                        )

                        // 3. 辅助光：灵犀狐焰温润金辉（极低透明度，仅作冷暖温度平衡）
                        glow(
                            LingXiTheme.atmosphereAmber,
                            0.12,
                            center: UnitPoint(x: 0.08, y: 0.85),
                            radius: span * 0.50,
                            size: geo.size
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 根据深浅模式、用户偏好强度与场景模式动态计算渐变，使用确定尺寸的矩形填充避免视图裁剪
    private func glow(_ color: Color, _ opacity: Double, center: UnitPoint, radius: CGFloat, size: CGSize) -> some View {
        let themeScale = colorScheme == .dark ? 1.0 : 0.35
        let effectiveOpacity = opacity * themeScale * preference.strength * modeStrength
        return Rectangle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(effectiveOpacity), .clear],
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .frame(width: size.width, height: size.height)
    }
}

public extension View {
    /// 让底层背景氛围（AtmosphereBackdrop）自然延伸穿透到系统 Sidebar 与 Inspector 后方 (macOS 26+ / iOS 26+)
    @ViewBuilder
    func lxBackgroundExtension() -> some View {
        #if canImport(SwiftUI)
        if #available(macOS 26.0, iOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
        #else
        self
        #endif
    }
}
