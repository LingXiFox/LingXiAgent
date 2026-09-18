import SwiftUI

/// LingXi Glass 视觉系统规范
/// 统一承载四级玻璃质感、蓝紫青绿环境光晕染色、超细边框与柔和微阴影。
public enum LingXiGlass {
    /// 四级玻璃材质层级
    public enum Tier {
        /// 底层主窗口背景玻璃 (沉浸通透)
        case window
        /// 次级侧边栏/检查器面板玻璃
        case panel
        /// 内容卡片/消息气泡玻璃
        case card
        /// 浮动操作栏/输入框/弹出层玻璃
        case floating

        public var blurRadius: CGFloat {
            switch self {
            case .window: return 40
            case .panel: return 24
            case .card: return 16
            case .floating: return 28
            }
        }

        public var backgroundOpacity: Double {
            switch self {
            case .window: return 0.72
            case .panel: return 0.65
            case .card: return 0.50
            case .floating: return 0.82
            }
        }

        public var borderOpacity: Double {
            switch self {
            case .window: return 0.15
            case .panel: return 0.18
            case .card: return 0.22
            case .floating: return 0.35
            }
        }
    }

    /// Cyber Fox 环境色盘
    public enum Palette {
        public static let deepBackground = Color(red: 0.05, green: 0.06, blue: 0.09)
        public static let surfaceElevated = Color(red: 0.09, green: 0.11, blue: 0.16)
        
        // 主题主调：蓝紫光晕
        public static let cyberCyan = Color(red: 0.18, green: 0.80, blue: 0.95)
        public static let neonPurple = Color(red: 0.65, green: 0.35, blue: 0.98)
        public static let foxOrange = Color(red: 1.00, green: 0.55, blue: 0.20)
        public static let matrixGreen = Color(red: 0.20, green: 0.88, blue: 0.55)
        
        // 状态色彩
        public static let statusSuccess = Color(red: 0.20, green: 0.85, blue: 0.55)
        public static let statusWarning = Color(red: 1.00, green: 0.72, blue: 0.25)
        public static let statusDanger = Color(red: 1.00, green: 0.33, blue: 0.38)
        public static let statusInfo = Color(red: 0.30, green: 0.65, blue: 1.00)

        // 文本阶梯
        public static let textPrimary = Color.white.opacity(0.95)
        public static let textSecondary = Color.white.opacity(0.68)
        public static let textTertiary = Color.white.opacity(0.42)
    }
}

/// 玻璃容器修饰符
public struct GlassmorphicModifier: ViewModifier {
    public let tier: LingXiGlass.Tier
    public let cornerRadius: CGFloat
    public let ambientColor: Color?

    public init(
        tier: LingXiGlass.Tier = .card,
        cornerRadius: CGFloat = 12,
        ambientColor: Color? = nil
    ) {
        self.tier = tier
        self.cornerRadius = cornerRadius
        self.ambientColor = ambientColor
    }

    public func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // 环境微光晕染色层
                    if let ambient = ambientColor {
                        ambient
                            .opacity(0.08)
                            .blur(radius: tier.blurRadius)
                    }
                    
                    // 核心材质基底
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LingXiGlass.Palette.deepBackground.opacity(tier.backgroundOpacity))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // 超细发光边缘 (0.5pt Hairline Glow Border)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(tier.borderOpacity),
                                (ambientColor ?? LingXiGlass.Palette.cyberCyan).opacity(tier.borderOpacity * 0.8),
                                Color.white.opacity(tier.borderOpacity * 0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
            .shadow(
                color: Color.black.opacity(tier == .floating ? 0.45 : 0.20),
                radius: tier == .floating ? 16 : 8,
                x: 0,
                y: tier == .floating ? 8 : 4
            )
    }
}

public extension View {
    func lingXiGlass(
        tier: LingXiGlass.Tier = .card,
        cornerRadius: CGFloat = 12,
        ambientColor: Color? = nil
    ) -> some View {
        modifier(GlassmorphicModifier(tier: tier, cornerRadius: cornerRadius, ambientColor: ambientColor))
    }
}
