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
