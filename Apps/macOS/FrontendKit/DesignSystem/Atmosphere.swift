import SwiftUI

/// Surface roles retained for the settings and workspace call sites.
public enum AtmosphereMode: Sendable, Equatable {
    case workspace
    case empty
    case settings
}

/// The window owns the static wallpaper and gradient; surfaces only add a tint.
public struct AtmosphereBackdrop: View {
    public var mode: AtmosphereMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(mode: AtmosphereMode = .workspace) {
        self.mode = mode
    }

    public var body: some View {
        Group {
            if reduceTransparency {
                mode == .settings ? LXColor.window : LXColor.content
            } else {
                Color.black.opacity(0.06)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
