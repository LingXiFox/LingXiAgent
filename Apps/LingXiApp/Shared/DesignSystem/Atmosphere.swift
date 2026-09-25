import SwiftUI

/// 赛博深空极光背景：深邃黑曜石底场 ✕ 多重梦幻极光弥散光斑
///
/// 性能零负担模型（Zero GPU Burden）：
/// 纯 CoreAnimation 硬件加速静态径向渐变（RadialGradient），无每帧着色器计算，
/// 仅在窗口尺寸或外观变更时更新，空闲时为零 GPU/CPU 循环占用。
struct AtmosphereBackdrop: View {
    @AppStorage(LXPreferenceKey.atmosphere) private var preference = AtmospherePreference.subtle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 深邃暗夜黑曜石底色
            LingXiTheme.deepNightBackground

            if preference != .off {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let span = max(w, h)

                    ZStack {
                        // 1. 左上深空星云靛蓝
                        glow(LingXiTheme.atmosphereIndigo, 0.42, center: UnitPoint(x: 0.12, y: 0.08), radius: span * 0.70)
                        // 2. 右侧幻视星轨紫
                        glow(LingXiTheme.atmosphereViolet, 0.32, center: UnitPoint(x: 0.75, y: 0.25), radius: span * 0.55)
                        // 3. 右下角电光青绿极光（生命与网络脉冲感）
                        glow(LingXiTheme.atmosphereTeal, 0.35, center: UnitPoint(x: 0.90, y: 0.88), radius: span * 0.60)
                        // 4. 左下角灵犀狐焰金光（温暖而轻盈的品牌灵魂光晕）
                        glow(LingXiTheme.atmosphereAmber, 0.20, center: UnitPoint(x: 0.05, y: 0.92), radius: span * 0.45)
                        // 5. 顶栏水平光束漫射（强化窗口上边缘的高级质感）
                        LinearGradient(
                            colors: [
                                LingXiTheme.electricCyan.opacity(colorScheme == .dark ? 0.08 * preference.strength : 0.03),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .init(x: 0.5, y: 0.20)
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 浅色模式保持相同色相但降低浓度，深色模式展现璀璨极光
    private func glow(_ color: Color, _ opacity: Double, center: UnitPoint, radius: CGFloat) -> some View {
        let scale = colorScheme == .dark ? 1.0 : 0.38
        return RadialGradient(
            colors: [color.opacity(opacity * scale * preference.strength), .clear],
            center: center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

extension View {
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

