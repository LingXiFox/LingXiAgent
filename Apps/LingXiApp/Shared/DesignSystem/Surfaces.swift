import SwiftUI

// MARK: - Surfaces
//
// Three kinds of surface exist, and only three:
// - Panel: sidebar / stage / inspector. bg-window or bg-content, radius-panel,
//   1px separator ring, NO shadow.
// - Floating surface: composer, permission, question, palette. Untinted Liquid
//   Glass on macOS 26 (surface-elevated + ring + shadow-float before that).
// - Content: messages, events, output. No card, no border, no shadow, no glass.

public extension View {
    /// 1px separator ring drawn inside `cornerRadius`.
    func lxRing(cornerRadius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LXColor.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    /// Panel: a filled rounded rect with a separator ring and no shadow.
    func lxPanel(_ fill: Color = LXColor.window, cornerRadius: CGFloat = LingXiMetrics.Radius.panel) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .lxRing(cornerRadius: cornerRadius)
    }

    /// Floating surface chrome: untinted glass, ring, shadow-float.
    @ViewBuilder
    func lxFloating(cornerRadius: CGFloat = LingXiMetrics.Radius.surface) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
                .lxRing(cornerRadius: cornerRadius)
        } else {
            self.background(LXColor.elevated, in: shape)
                .lxRing(cornerRadius: cornerRadius)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 8)
        }
    }

    /// Stable identity for glass shapes that morph inside one `LXGlassGroup`.
    @ViewBuilder
    func lxGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Read-only inset block: fill-quinary, radius-inset, 8 × 12 padding.
    func lxInsetBlock() -> some View {
        padding(.horizontal, LingXiMetrics.Space.md)
            .padding(.vertical, LingXiMetrics.Space.sm)
            .background(LXColor.fillQuinary,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
    }
}

/// Neighbouring glass shapes sample one backdrop and morph into each other.
public struct LXGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = LingXiMetrics.Space.sm, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// FloatingSurface: radius-surface, padding space-lg, children gap space-md.
public struct LXFloatingSurface<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            content
        }
        .padding(LingXiMetrics.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lxFloating()
    }
}

/// Floating-surface head: icon (18) + headline + trailing accessory.
public struct LXSurfaceHead<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let trailing: Trailing

    public init(symbol: String, tint: Color = LXColor.accentText, title: String,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: LXIcon.surfaceHead))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(LXType.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LingXiMetrics.Space.sm)
            trailing
        }
    }
}

// MARK: - Buttons
//
// One accent per surface: only `.lxPrimary` fills with Fox orange. Everything
// else stays neutral and never turns blue, teal or purple.

public struct LXButtonStyle: ButtonStyle {
    public enum Role: Sendable { case primary, secondary, destructive, plain }
    public enum Size: Sendable { case small, regular, large }

    let role: Role
    let size: Size

    public init(_ role: Role = .secondary, size: Size = .regular) {
        self.role = role
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        LXButtonBody(label: configuration.label, isPressed: configuration.isPressed, role: role, size: size)
    }
}

private struct LXButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let role: LXButtonStyle.Role
    let size: LXButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(fill, in: shape)
            .overlay {
                if isHovered && isEnabled && role != .primary {
                    shape.fill(LXColor.fillQuinary).allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }

    private var height: CGFloat {
        switch size {
        case .small: return LXControl.small
        case .regular: return LXControl.regular
        case .large: return LXControl.large
        }
    }

    private var radius: CGFloat {
        size == .small ? LingXiMetrics.Radius.sm : LingXiMetrics.Radius.control
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return 10
        case .regular: return 14
        case .large: return 18
        }
    }

    private var font: Font {
        switch size {
        case .small: return LXType.meta.weight(.medium)
        case .regular: return LXType.body.weight(.medium)
        case .large: return Font.system(size: 14, weight: .medium)
        }
    }

    private var foreground: AnyShapeStyle {
        switch role {
        case .primary: return AnyShapeStyle(LXColor.onAccent)
        case .destructive: return AnyShapeStyle(LXColor.danger)
        case .secondary, .plain: return AnyShapeStyle(.primary)
        }
    }

    private var fill: AnyShapeStyle {
        switch role {
        case .primary: return AnyShapeStyle(LXColor.accent.opacity(isPressed ? 0.85 : 1))
        case .secondary, .destructive: return AnyShapeStyle(LXColor.fillControl)
        case .plain: return AnyShapeStyle(isPressed ? LXColor.fillControl : Color.clear)
        }
    }
}

public extension ButtonStyle where Self == LXButtonStyle {
    static var lxPrimary: LXButtonStyle { LXButtonStyle(.primary) }
    static var lxSecondary: LXButtonStyle { LXButtonStyle(.secondary) }
    static var lxDestructive: LXButtonStyle { LXButtonStyle(.destructive) }
    static var lxPlain: LXButtonStyle { LXButtonStyle(.plain) }
    static var lxSmall: LXButtonStyle { LXButtonStyle(.secondary, size: .small) }
}

/// Icon-only round button (radius-pill). Callers must add an accessibilityLabel.
public struct LXIconButtonStyle: ButtonStyle {
    let side: CGFloat
    let isOn: Bool

    public init(side: CGFloat = LXControl.regular, isOn: Bool = false) {
        self.side = side
        self.isOn = isOn
    }

    public func makeBody(configuration: Configuration) -> some View {
        LXIconButtonBody(label: configuration.label, isPressed: configuration.isPressed, side: side, isOn: isOn)
    }
}

private struct LXIconButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let side: CGFloat
    let isOn: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .font(.system(size: LXIcon.chip))
            .foregroundStyle(isOn ? AnyShapeStyle(LXColor.accentText) : AnyShapeStyle(.secondary))
            .frame(width: side, height: side)
            .background(isPressed || isHovered ? LXColor.fillControl : .clear, in: Circle())
            .contentShape(Circle())
            .onHover { isHovered = $0 }
    }
}

/// Key hint inside a button label, e.g. `允许 ⏎`: 11.5 regular at 75%.
public struct LXKeyHintLabel: View {
    let title: String
    let hint: String

    public init(_ title: String, hint: String) {
        self.title = title
        self.hint = hint
    }

    public var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Text(title)
            Text(hint)
                .font(.system(size: 11.5))
                .opacity(0.75)
        }
    }
}

// MARK: - Chip

/// The composer's single control style: 28 tall, radius-control, fill-control,
/// icon 14 + 13 medium label + caret. A SwiftUI `Menu` label is rendered by
/// AppKit and drops custom backgrounds, so the chip paints its fill around the
/// menu rather than inside the label.
public struct LXChipMenu<Items: View>: View {
    let title: String
    let symbol: String
    let help: String
    let items: Items
    @State private var isHovered = false

    public init(_ title: String, symbol: String, help: String, @ViewBuilder items: () -> Items) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.items = items()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control, style: .continuous)
        Menu {
            items
        } label: {
            Label(title, systemImage: symbol)
                .font(LXType.body.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(.primary)
        .foregroundStyle(.primary)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: LXControl.regular)
        .background(LXColor.fillControl, in: shape)
        .overlay { if isHovered { shape.fill(LXColor.fillQuinary).allowsHitTesting(false) } }
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
