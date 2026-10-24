import AppKit
import BezierCore
import SwiftUI

/// Colours derived from a Space theme, in the spirit of Arc's semantic palette
/// (background / foreground / hover / focus / subtitle …). Values come from TBC's farewell
/// CSS and Arc.app's asset catalogs: see references/design/design-language.md §0, §3.
struct ThemePalette: Equatable {
    let isDark: Bool
    let frameColors: [NSColor]
    /// URL pill + favorite tile fill ("well").
    let well: Color
    let wellHover: Color
    let ink: Color
    let inkSecondary: Color
    /// Space name, section headers.
    let muted: Color
    let icon: Color
    let iconDisabled: Color
    let hairline: Color
    let rowHover: Color
    let activeTab: Color
    let newTab: Color
    let accent: Color
    let grainOpacity: Float
    /// Opacity of the theme tint over the behind-window blur (1 = solid, Arc's default look).
    let tintOpacity: Float
    /// Liquid Glass (macOS 26): the Space colour tints the glass itself; a lighter gradient
    /// rides on top so multi-colour themes still read as gradients.
    let glassTint: NSColor
    let glassGradientOpacity: Float
    /// The floating sidebar slides over the page, so it tints much less: the page should read
    /// through it (still regular, frosted glass so the sidebar text stays legible).
    let floatingGlassTint: NSColor
    let floatingGradientOpacity: Float
    let cardHairline: NSColor

    init(theme: SpaceTheme, systemIsDark: Bool) {
        let dark: Bool = switch theme.appearance {
        case .dark: true
        case .light: false
        case .automatic: systemIsDark
        }
        isDark = dark

        let washed = theme.colors.map { $0.mixed(with: dark ? RGBA(hex: 0x3A3A40) : .white, 1 - theme.intensity) }
        // Neutral: system-like greys with a whisper of vertical shading, no hue.
        let neutralStops = dark ? [RGBA(hex: 0x26262A), RGBA(hex: 0x1D1D20)] : [RGBA(hex: 0xF4F4F6), RGBA(hex: 0xE8E8EC)]
        let stops = theme.isNeutral ? neutralStops : (dark ? washed.map(Self.darkened) : washed)
        frameColors = stops.map(\.nsColor)
        let base = stops.reduce(RGBA(0, 0, 0, 0)) {
            let n = Double(stops.count)
            return RGBA($0.r + $1.r / n, $0.g + $1.g / n, $0.b + $1.b / n, 1)
        }

        if dark {
            well = Color.white.opacity(0.08)
            wellHover = Color.white.opacity(0.12)
            ink = Color.white.opacity(0.9)
            inkSecondary = Color.white.opacity(0.55)
            muted = Color.white.opacity(0.5)
            icon = Color.white.opacity(0.62)
            iconDisabled = Color.white.opacity(0.22)
            hairline = Color.white.opacity(0.1)
            rowHover = Color.white.opacity(0.07)
            activeTab = Color.white.opacity(0.16)
            newTab = Color.white.opacity(0.5)
            cardHairline = NSColor.white.withAlphaComponent(0.08)
        } else {
            // On coral #ff8a91 the CSS uses well #f47b82, label #aa4d52, pill #fff5f4.
            let shade = theme.isNeutral ? RGBA(hex: 0x3C3C43) : base.scaled(0.42)
            well = Color.black.opacity(0.055)
            wellHover = Color.black.opacity(0.08)
            ink = Color.black.opacity(0.86)
            inkSecondary = Color.black.opacity(0.5)
            muted = shade.withAlpha(0.72).color
            icon = Color.black.opacity(0.62)
            iconDisabled = Color.black.opacity(0.22)
            hairline = shade.withAlpha(0.12).color
            rowHover = Color.black.opacity(0.05)
            activeTab = theme.isNeutral ? Color.white : base.mixed(with: .white, 0.9).color
            newTab = shade.withAlpha(0.6).color
            cardHairline = shade.withAlpha(0.18).nsColor
        }
        accent = (theme.accent ?? Self.accent(for: theme.isNeutral ? RGBA(hex: 0x8489FF) : base, dark: dark)).color
        grainOpacity = Float(theme.grain * 0.12)
        // Never fully clear: the theme colour is how you know which Space you're in.
        let translucency = min(1, max(0, theme.translucency))
        tintOpacity = Float(1 - translucency * 0.72)
        glassTint = base.withAlpha(0.25 + (1 - translucency) * 0.6).nsColor
        glassGradientOpacity = Float((1 - translucency) * 0.65)
        floatingGlassTint = base.withAlpha(0.08 + (1 - translucency) * 0.4).nsColor
        floatingGradientOpacity = Float((1 - translucency) * 0.28)
    }

    static func == (a: Self, b: Self) -> Bool {
        a.isDark == b.isDark && a.frameColors == b.frameColors && a.grainOpacity == b.grainOpacity && a.tintOpacity == b.tintOpacity
    }

    private static func darkened(_ c: RGBA) -> RGBA {
        c.luminance < 0.2 ? c : c.mixed(with: RGBA(hex: 0x1D1D22), 0.78)
    }

    /// Saturated version of the theme hue for the Command Bar selection and focus rings
    /// (Arc's default pastel theme uses periwinkle #8489FF).
    private static func accent(for base: RGBA, dark: Bool) -> RGBA {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        base.nsColor.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        if s < 0.08 { return RGBA(hex: 0x8489FF) }
        let c = NSColor(hue: h, saturation: max(0.5, min(0.75, s * 2.2)), brightness: dark ? 0.85 : 0.88, alpha: 1)
        return RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}
