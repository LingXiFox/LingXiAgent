import SwiftUI

/// Static ambient backdrop behind the stage: the window background plus three
/// soft, low-saturation glows that give floating glass something to refract.
///
/// Cost model: plain gradients with no animation, redrawn only when the window
/// size or appearance changes; idle frames composite a cached layer. Glow
/// strength follows the user's preference and drops to zero when off.
struct AtmosphereBackdrop: View {
    @AppStorage(LXPreferenceKey.atmosphere) private var preference = AtmospherePreference.subtle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LingXiTheme.windowBackground
            if preference != .off {
                GeometryReader { geo in
                    let span = max(geo.size.width, geo.size.height)
                    ZStack {
                        glow(LingXiTheme.atmosphereIndigo, 0.34, center: UnitPoint(x: 0.08, y: 0.05), radius: span * 0.65)
                        glow(LingXiTheme.atmosphereTeal, 0.22, center: UnitPoint(x: 0.95, y: 0.92), radius: span * 0.55)
                        glow(LingXiTheme.atmosphereViolet, 0.18, center: UnitPoint(x: 0.62, y: 0.30), radius: span * 0.45)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Light mode keeps the same hues at a third of the strength so glass stays clean.
    private func glow(_ color: Color, _ opacity: Double, center: UnitPoint, radius: CGFloat) -> some View {
        let scale = colorScheme == .dark ? 1.0 : 0.35
        return RadialGradient(
            colors: [color.opacity(opacity * scale * preference.strength), .clear],
            center: center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

extension View {
    /// Floating side surface (navigator, inspector): one glass shape per panel,
    /// never nested, never per-row.
    func lxFloatingPanel(_ material: PanelMaterialPreference) -> some View {
        lxGlass(in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.panel, style: .continuous),
                tint: material == .tinted ? LingXiTheme.panelTint : nil)
    }
}
