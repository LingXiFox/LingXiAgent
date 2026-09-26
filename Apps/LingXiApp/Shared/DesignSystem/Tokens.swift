import SwiftUI
import AppKit

// MARK: - LingXiAgent Design System · tokens
//
// Single source of truth for every colour, type style, spacing step, radius and
// layout size in the macOS GUI. Values mirror the "LingXiAgent" design system
// artifact (`project/tokens.json`). Views never write a literal number or hex:
// change the token here instead.
//
// Colour layers:
// - structure → macOS semantic colours (window, content, labels, separator)
// - interactive brand → Fox orange, the ONE accent
// - ambient brand → Indigo (thinking) / Teal (running), icons and dots only
// - status → Apple increased-contrast system colours

// MARK: Brand primitives

/// Raw brand swatches. Only semantic tokens, the empty-state mark and the about
/// mark read these; components go through `LXColor`.
public enum LXBrand {
    static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    public static let fox600 = Color(nsColor: srgb(0xB3430F))
    public static let fox500 = Color(nsColor: srgb(0xC24A14))
    public static let fox300 = Color(nsColor: srgb(0xF28A55))
    public static let indigo600 = Color(nsColor: srgb(0x4A4FC0))
    public static let indigo500 = Color(nsColor: srgb(0x5B5FD6))
    public static let indigo300 = Color(nsColor: srgb(0x9EA2F5))
    public static let teal600 = Color(nsColor: srgb(0x0E8A85))
    public static let teal500 = Color(nsColor: srgb(0x16A39C))
    public static let teal300 = Color(nsColor: srgb(0x3CC9BD))
    /// Warm ink: app mark and empty-state art only, never a UI ground.
    public static let ink900 = Color(nsColor: srgb(0x1A1410))
    /// Milk: the mark's base in dark appearance.
    public static let milk50 = Color(nsColor: srgb(0xF6F1E8))
}

// MARK: Semantic colours

public enum LXColor {
    /// Appearance-aware colour: (light, dark) hex with per-appearance alpha.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? LXBrand.srgb(dark, alpha: darkAlpha)
                : LXBrand.srgb(light, alpha: lightAlpha)
        })
    }

    // Structure — system semantic colours, so Increase Contrast and Reduce
    // Transparency are honoured by the OS.

    /// bg-window: window ground, settings, behind panels.
    public static let window = Color(nsColor: .windowBackgroundColor)
    /// bg-content: conversation stage, code and tables.
    public static let content = Color(nsColor: .textBackgroundColor)
    /// surface-elevated: the solid stand-in for floating glass.
    public static let elevated = adaptive(light: 0xFFFFFF, dark: 0x2A2A2A)
    /// separator: hairlines and the 1px ring of panels and surfaces.
    public static let separator = Color(nsColor: .separatorColor)
    /// fill-quinary: inset / output blocks, badges.
    public static let fillQuinary = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.05)
    /// fill-control: secondary buttons, chips, selected rows and tabs.
    public static let fillControl = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.12)
    /// fill-bubble: the user bubble, ~6% wash that flips with appearance.
    public static let fillBubble = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)

    // Interactive brand — the ONE accent.

    /// accent: primary button fill, selection indicator, determinate progress,
    /// goal, anything waiting on a human. One accent fill per surface.
    public static let accent = LXBrand.fox500
    /// accent-text: accent as text or icon (≥4.5:1 on the window ground).
    public static let accentText = adaptive(light: 0xB3430F, dark: 0xF28A55)
    /// on-accent: text and glyphs on an accent fill.
    public static let onAccent = Color.white
    /// accent-soft: goal chip, selected option row.
    public static let accentSoft = adaptive(light: 0xC24A14, dark: 0xC24A14, lightAlpha: 0.10, darkAlpha: 0.22)

    // Ambient brand — icons, 6pt dots and progress rings only.

    /// thinking-accent (Indigo).
    public static let thinking = adaptive(light: 0x4A4FC0, dark: 0x9EA2F5)
    /// running-accent (Teal).
    public static let running = adaptive(light: 0x0E8A85, dark: 0x3CC9BD)
    public static let ambientIndigo = adaptive(light: 0x5B5FD6, dark: 0x6B6FEB, lightAlpha: 0.06, darkAlpha: 0.13)
    public static let ambientTeal = adaptive(light: 0x16A39C, dark: 0x2EC4B8, lightAlpha: 0.045, darkAlpha: 0.09)
    public static let ambientFox = adaptive(light: 0xC24A14, dark: 0xC24A14, lightAlpha: 0.015, darkAlpha: 0.035)

    // Status — increased-contrast system variants; they tint icons and dots.

    public static let success = adaptive(light: 0x248A3D, dark: 0x30DB5B)
    public static let warning = adaptive(light: 0xB25000, dark: 0xFFD426)
    public static let danger = adaptive(light: 0xD70015, dark: 0xFF6961)
    public static let info = adaptive(light: 0x0040DD, dark: 0x409CFF)
    public static let diffAdd = adaptive(light: 0x248A3D, dark: 0x30DB5B, lightAlpha: 0.10, darkAlpha: 0.14)
    public static let diffRemove = adaptive(light: 0xD70015, dark: 0xFF6961, lightAlpha: 0.08, darkAlpha: 0.14)
}

/// Status roles. State is always icon + text; colour only lands on the icon.
public enum LXStatus {
    public static let running = LXColor.running
    public static let thinking = LXColor.thinking
    public static let actionRequired = LXColor.accent
    public static let success = LXColor.success
    public static let warning = LXColor.warning
    public static let error = LXColor.danger
    public static let info = LXColor.info
}

// MARK: Typography

/// Type ramp. System font (SF Pro, PingFang SC fallback) and SF Mono only.
/// Nothing below `micro` 11.5 — the 9–11pt range is forbidden.
public enum LXType {
    /// message 16/26 — assistant prose and user messages.
    public static let message = Font.system(size: 16)
    /// display 28/34 semibold — empty state and about only, once per screen.
    public static let display = Font.system(size: 28, weight: .semibold)
    /// title 20/26 semibold — stage and settings block titles.
    public static let title = Font.system(size: 20, weight: .semibold)
    /// headline 15/20 semibold — floating-surface titles.
    public static let headline = Font.system(size: 15, weight: .semibold)
    /// callout 14/20 medium — timeline events, inspector body, options.
    public static let callout = Font.system(size: 14, weight: .medium)
    /// body 13/18 — controls, menus, settings rows.
    public static let body = Font.system(size: 13)
    /// meta 12.5/17 — durations, counts, subtitles, status labels.
    public static let meta = Font.system(size: 12.5)
    /// Section heads: meta semibold, text-secondary.
    public static let sectionHead = Font.system(size: 12.5, weight: .semibold)
    /// micro 11.5/14 semibold — badges.
    public static let micro = Font.system(size: 11.5, weight: .semibold)
    /// mono 13.5/20 — commands, paths, IDs.
    public static let mono = Font.system(size: 13.5, design: .monospaced)
    /// mono-sm 12.5/18 — output blocks and diffs.
    public static let monoSmall = Font.system(size: 12.5, design: .monospaced)
    /// Composer editor and question body 15/22.
    public static let editor = Font.system(size: 15)
    /// Expanded reasoning 14/22.
    public static let thinkingBody = Font.system(size: 14, weight: .medium)

    /// Extra leading that turns the system line height into the token's.
    public enum Leading {
        /// message 16 → 26
        public static let message: CGFloat = 7
        /// editor 15 → 22
        public static let editor: CGFloat = 4
        /// thinking 14 → 22
        public static let thinking: CGFloat = 5
        /// mono 13.5 → 20
        public static let mono: CGFloat = 4
    }
}

// MARK: Icon sizes

/// SF Symbol body sizes per slot, so no call site invents one.
public enum LXIcon {
    /// Toolbar glyph 17.
    public static let toolbar: CGFloat = 17
    /// Floating-surface head icon 18.
    public static let surfaceHead: CGFloat = 18
    /// Sidebar row icon 15.
    public static let row: CGFloat = 15
    /// Timeline event glyph 15 in the 18pt column.
    public static let event: CGFloat = 15
    /// Chip leading icon 14.
    public static let chip: CGFloat = 14
    /// Status icon beside a meta label 14.
    public static let status: CGFloat = 14
    /// Composer context strip 13.
    public static let strip: CGFloat = 13
    /// Copy / goal / trailing chevron 12.
    public static let small: CGFloat = 12
    /// Chip caret 11.
    public static let caret: CGFloat = 11
    /// Empty / unavailable state glyph 26.
    public static let emptyState: CGFloat = 26
}

// MARK: Control sizes

public enum LXControl {
    /// Button / chip regular 28.
    public static let regular: CGFloat = 28
    /// Button small, copy button, goal chip 22.
    public static let small: CGFloat = 22
    /// Button large, toolbar control 36.
    public static let large: CGFloat = 36
    /// Badge 20.
    public static let badge: CGFloat = 20
    /// Inspector tab 24.
    public static let tab: CGFloat = 24
    /// Toolbar button hit target 32 × 28.
    public static let toolbarWidth: CGFloat = 32
    /// Status dot 6.
    public static let dot: CGFloat = 6
    /// Spinner ring 12.
    public static let spinner: CGFloat = 12
    /// Option mark 16.
    public static let optionMark: CGFloat = 16
    /// Settings provider glyph tile 28.
    public static let tile: CGFloat = 28
}

// MARK: Metrics

public enum LingXiMetrics {
    /// Spacing — only these steps; `panelInset` 14 is the one exception.
    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let panelInset: CGFloat = 14
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
        public static let xxxxl: CGFloat = 48
    }

    /// Radii, concentric from the 26pt window corner.
    public enum Radius {
        public static let sm: CGFloat = 6
        public static let inset: CGFloat = 8
        public static let control: CGFloat = 10
        /// radius-window − space-sm
        public static let panel: CGFloat = 18
        public static let bubble: CGFloat = 18
        public static let surface: CGFloat = 20
        public static let window: CGFloat = 26
    }

    public enum Size {
        public static let toolbar: CGFloat = 52
        public static let rowEvent: CGFloat = 36
        public static let rowList: CGFloat = 34
        public static let sidebarHead: CGFloat = 44
        public static let formRow: CGFloat = 44
        public static let menuItem: CGFloat = 28
        public static let glyphColumn: CGFloat = 18
        public static let navigator: CGFloat = 280
        public static let navigatorMin: CGFloat = 220
        /// Inspector 340.
    public static let inspector: CGFloat = 340
        public static let inspectorMin: CGFloat = 300
        /// Wider than this, the inspector docks; narrower, it floats over the stage.
        public static let inspectorDockWidth: CGFloat = 1120
        /// Trailing launcher strip for the workbench dock.
        public static let dockRail: CGFloat = 40
        public static let windowMinWidth: CGFloat = 760
        public static let windowMinHeight: CGFloat = 520
    }

    public enum Column {
        /// measure-prose: message reading column.
        public static let prose: CGFloat = 720
        /// measure-stage: diffs, tables and output blocks may use this width.
        public static let stage: CGFloat = 1080
        /// bubble-max.
        public static let bubble: CGFloat = 640
        /// size-gutter: minimum side margin of the reading column.
        public static let gutter: CGFloat = 28
        /// Floating surface cap (permission, question).
        public static let surface: CGFloat = 560
        /// Settings content column.
        public static let settings: CGFloat = 760
        /// Settings sidebar.
        public static let settingsSidebar: CGFloat = 230
        /// Command palette.
        public static let palette: CGFloat = 640
    }

    /// output-max: output blocks cap here and scroll inside.
    public static let outputMaxHeight: CGFloat = 260
    /// Composer editor grows to this many lines, then scrolls.
    public static let composerMaxLines = 8
    /// Composer editor minimum height.
    public static let composerMinHeight: CGFloat = 44
    /// Timeline detail indent = glyph column + column gap.
    public static let detailIndent: CGFloat = Size.glyphColumn + Space.sm
}

// MARK: Motion

/// Every animation goes through here so Reduce Motion is honoured in one place.
public enum LXMotion {
    /// smooth 0.22s
    public static let standard: Animation = .smooth(duration: 0.22)
    /// snappy 0.18s
    public static let disclosure: Animation = .snappy(duration: 0.18)

    public static func animation(_ base: Animation = standard, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}
