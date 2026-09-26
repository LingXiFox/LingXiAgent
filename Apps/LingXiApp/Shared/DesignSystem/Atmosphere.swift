import SwiftUI

/// 氛围场景。设计系统只允许三档强度：
/// workspace 为标准档，empty 为全产品最强档，settings 明显弱于 workspace。
public enum AtmosphereMode: Sendable, Equatable {
    case workspace
    case empty
    case settings
}

/// 环境光背景：房间里的间接照明，不是壁纸。
///
/// 设计系统契约（`Docs/design/LingXiAgent-design-system.html` §AmbientBackdrop）：
/// - 中性底占绝对主体，感知比例目标：中性 90–95%、靛 4–7%、青 3–5%、狐橙 0–2%
/// - 三个光源的圆心一律落在视图边界之外，终止半径约为长边的 1.1–1.4 倍，
///   因此看不见光心、看不见圆斑、看不见渐变边界、不会四角四色
/// - 不使用 blur / backdrop-filter，纯静态：空闲时零刷新、零 GPU 循环
/// - 减弱透明度 → 关闭光层；增强对比度 → 强度减半
/// - 仅用于工作区舞台与设置窗口。侧栏、检查器、浮层、卡片、菜单、Sheet 一律不使用
public struct AtmosphereBackdrop: View {
    public var mode: AtmosphereMode
    @AppStorage(LXPreferenceKey.atmosphere) private var preference = AtmospherePreference.subtle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(mode: AtmosphereMode = .workspace) {
        self.mode = mode
    }

    /// 设置页为 is-quiet = 0.4；其余为 1.0
    private var modeStrength: Double {
        switch mode {
        case .workspace, .empty: return 1.0
        case .settings: return 0.4
        }
    }

    private var enhancedContrast: Bool { contrast == .increased }

    public var body: some View {
        ZStack {
            base
            if preference != .off && !reduceTransparency {
                GeometryReader { geo in
                    lights(in: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 底色。工作区舞台用内容底；设置窗口用窗口底。
    private var base: Color {
        mode == .settings ? LXColor.window : LXColor.content
    }

    @ViewBuilder
    private func lights(in size: CGSize) -> some View {
        let span = max(size.width, size.height)
        let halve = enhancedContrast ? 0.5 : 1.0
        let strength = preference.strength * modeStrength * halve

        ZStack {
            if mode == .empty {
                // 光源略近，终止 72%
                light(LXColor.ambientIndigo, center: UnitPoint(x: -0.15, y: -0.25),
                      radius: span * 0.91, size: size)
                light(LXColor.ambientTeal, center: UnitPoint(x: 1.15, y: 1.25),
                      radius: span * 0.84, size: size)
                light(LXColor.ambientFox, center: UnitPoint(x: -0.10, y: 1.20),
                      radius: span * 0.49, size: size)
            } else {
                // 靛：左上框外主光
                light(LXColor.ambientIndigo, center: UnitPoint(x: -0.25, y: -0.35),
                      radius: span * 0.98, size: size)
                // 青：右下框外次光
                light(LXColor.ambientTeal, center: UnitPoint(x: 1.25, y: 1.35),
                      radius: span * 0.77, size: size)
                // 狐橙：左下框外冷暖配平，几乎不可察觉
                light(LXColor.ambientFox, center: UnitPoint(x: -0.15, y: 1.25),
                      radius: span * 0.42, size: size)
            }
        }
        .opacity(strength)
    }

    private func light(_ color: Color, center: UnitPoint, radius: CGFloat, size: CGSize) -> some View {
        Rectangle()
            .fill(RadialGradient(
                colors: [color, .clear],
                center: center,
                startRadius: 0,
                endRadius: radius
            ))
            .frame(width: size.width, height: size.height)
    }
}
