import SwiftUI

// MARK: - Glass surfaces
//
// Glass is reserved for floating, temporary, interactive layers (mode switcher,
// composer, permission surface, overlay buttons). Content never gets glass.
// macOS 26+ uses the native Liquid Glass API; older systems fall back to the
// system material so accessibility settings (Reduce Transparency, Increase
// Contrast) are still honoured by the OS rather than by hand-rolled blur.

public extension View {
    /// Native glass surface clipped to `shape`.
    @ViewBuilder
    func lxGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Stable identity for glass shapes that morph inside the same `LXGlassGroup`.
    @ViewBuilder
    func lxGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Secondary glass button (overlay actions such as "jump to bottom").
    @ViewBuilder
    func lxGlassButtonStyle() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// The single primary action of a surface; the only place the brand tint fills a control.
    @ViewBuilder
    func lxPrimaryButtonStyle() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(LingXiTheme.accentColor)
        } else {
            self.buttonStyle(.borderedProminent).tint(LingXiTheme.accentColor)
        }
    }

    /// Floating bar attached to a scroll edge. On macOS 26+ it is a safe-area
    /// bar, so content scrolling beneath gets the system scroll-edge effect.
    @ViewBuilder
    func lxFloatingBar<Bar: View>(edge: VerticalEdge, @ViewBuilder bar: () -> Bar) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.safeAreaBar(edge: edge, spacing: 0, content: bar)
        } else {
            self.safeAreaInset(edge: edge, spacing: 0, content: bar)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Groups neighbouring glass shapes so they sample the same backdrop and can
/// morph into one another; a plain stack before macOS 26.
public struct LXGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = LingXiMetrics.Space.sm, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Motion

/// Short, content-led motion. Every call site goes through here so Reduce
/// Motion collapses all transitions to an instant change in one place.
public enum LXMotion {
    public static let standard: Animation = .smooth(duration: 0.22)
    public static let disclosure: Animation = .snappy(duration: 0.18)

    public static func animation(_ base: Animation = standard, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}

// MARK: - Quiet content primitives

public extension View {
    /// Read-only inset block for code, commands and tool output. Uses the
    /// system fill hierarchy instead of a gray literal, no border, no shadow.
    func lxInsetBlock() -> some View {
        self.background(.quinary, in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset,
                                                       style: .continuous))
    }
}

/// Continuous-document section: header, content, no card. Sections are separated
/// by the caller with `Divider()`, matching Xcode / Finder inspectors.
struct LXSection<Content: View, Accessory: View>: View {
    let title: String
    let content: Content
    let accessory: Accessory

    init(_ title: String,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.lxMeta.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Placeholder copy for an empty slot: one explanatory line, never a fake row.
struct PlaceholderLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.lxCallout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Crystal & Neon Specular Enhancements (Zero GPU Burden)

public extension View {
    /// 钻石切面 1px 线性渐变高光边框（参考 macOS 现代玻璃美学）
    /// 纯矢量计算，零 GPU/离屏重绘负担
    func lxCrystalBorder(cornerRadius: CGFloat = LingXiMetrics.Radius.surface,
                         glowColor: Color? = nil,
                         glowRadius: CGFloat = 8) -> some View {
        self.modifier(LXCrystalBorderModifier(cornerRadius: cornerRadius,
                                              glowColor: glowColor,
                                              glowRadius: glowRadius))
    }

    /// 晶体黑曜石卡片底板：微光磨砂玻璃 ✕ 1px 钻石切面 ✕ 可选微发光
    func lxCrystalCard(cornerRadius: CGFloat = LingXiMetrics.Radius.surface,
                       tint: Color? = nil,
                       glowColor: Color? = nil,
                       interactive: Bool = false) -> some View {
        self
            .lxGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                     tint: tint ?? LingXiTheme.obsidianSurface,
                     interactive: interactive)
            .lxCrystalBorder(cornerRadius: cornerRadius, glowColor: glowColor)
    }

    /// 霓虹微发光光晕（CoreAnimation 硬件加速，低能耗阴影模拟）
    func lxNeonGlow(color: Color, radius: CGFloat = 8, opacity: Double = 0.45) -> some View {
        self.shadow(color: color.opacity(opacity), radius: radius, x: 0, y: 0)
    }

    /// 晶莹胶囊徽章样式（用于状态、模式与标签）
    func lxNeonBadge(color: Color) -> some View {
        self
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .padding(.vertical, LingXiMetrics.Space.xs)
            .background {
                Capsule()
                    .fill(color.opacity(0.12))
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [color.opacity(0.65), color.opacity(0.20)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .lxNeonGlow(color: color, radius: 4, opacity: 0.25)
    }
}

/// 矢量高光描边修改器
struct LXCrystalBorderModifier: ViewModifier {
    let cornerRadius: CGFloat
    let glowColor: Color?
    let glowRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.24 : 0.45),
                                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.18),
                                Color.white.opacity(colorScheme == .dark ? 0.02 : 0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: glowColor?.opacity(colorScheme == .dark ? 0.35 : 0.18) ?? Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                radius: glowColor != nil ? glowRadius : 10,
                x: 0,
                y: glowColor != nil ? 0 : 4
            )
    }
}
