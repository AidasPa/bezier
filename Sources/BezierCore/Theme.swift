import Foundation

/// An sRGB colour with alpha, stored as 0...1 components.
public struct RGBA: Codable, Hashable, Sendable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    public func scaled(_ f: Double) -> RGBA { RGBA(r * f, g * f, b * f, a) }
    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
}

/// A Space's theme: a 1–3 stop gradient across the whole window frame, plus grain.
/// Mirrors Arc's model (blendedSingleColor / blendedGradient + noiseFactor + light/dark).
public struct SpaceTheme: Codable, Hashable, Sendable {
    public enum Appearance: String, Codable, Sendable { case automatic, light, dark }

    public var colors: [RGBA]
    public var appearance: Appearance
    /// 0...1, maps to grain overlay opacity.
    public var grain: Double
    /// 0...1, how strongly the colours show (Arc's `intensityFactor`); low values wash toward
    /// white on light themes and toward graphite on dark ones.
    public var intensity: Double
    /// 0...1, how much of the desktop shows through the window frame (Arc's `translucencyStyle`).
    public var translucency: Double
    /// No colour on the frame or sidebar: plain light/dark greys (following `appearance`), with
    /// `accent` carrying the Space's colour on highlights only.
    public var isNeutral: Bool
    /// Highlight colour (Command Bar selection, folders, progress). `nil` derives it from `colors`.
    public var accent: RGBA?

    public static let defaultTranslucency = 0.45

    public init(colors: [RGBA], appearance: Appearance = .light, grain: Double = 0.5, intensity: Double = 1,
                translucency: Double = SpaceTheme.defaultTranslucency, isNeutral: Bool = false, accent: RGBA? = nil) {
        precondition(!colors.isEmpty)
        self.colors = colors
        self.appearance = appearance
        self.grain = grain
        self.intensity = intensity
        self.translucency = translucency
        self.isNeutral = isNeutral
        self.accent = accent
    }

    private enum CodingKeys: String, CodingKey { case colors, appearance, grain, intensity, translucency, isNeutral, accent }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colors = try c.decode([RGBA].self, forKey: .colors)
        appearance = try c.decode(Appearance.self, forKey: .appearance)
        grain = try c.decode(Double.self, forKey: .grain)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 1
        translucency = try c.decodeIfPresent(Double.self, forKey: .translucency) ?? Self.defaultTranslucency
        isNeutral = try c.decodeIfPresent(Bool.self, forKey: .isNeutral) ?? false
        accent = try c.decodeIfPresent(RGBA.self, forKey: .accent)
        if colors.isEmpty { colors = [RGBA(hex: 0xD9D2F7)] }
    }

    public var average: RGBA {
        let n = Double(colors.count)
        return colors.reduce(RGBA(0, 0, 0, 0)) { RGBA($0.r + $1.r / n, $0.g + $1.g / n, $0.b + $1.b / n, $0.a + $1.a / n) }
    }

    // Presets taken from Arc's Dec 2022 theme picker swatches (references/design/design-language.md §3).
    public static let lavender = SpaceTheme(colors: [RGBA(hex: 0xD9D2F7), RGBA(hex: 0xF1C9DE)])
    public static let coral = SpaceTheme(colors: [RGBA(hex: 0xFF8A91)])
    public static let sky = SpaceTheme(colors: [RGBA(hex: 0xBFE0EF), RGBA(hex: 0x8FC5DE)])
    public static let mint = SpaceTheme(colors: [RGBA(hex: 0xC9F3D9), RGBA(hex: 0x82E7AC)])
    public static let sand = SpaceTheme(colors: [RGBA(hex: 0xF4EEEA), RGBA(hex: 0xF5DC80)])
    public static let graphite = SpaceTheme(colors: [RGBA(hex: 0x2B2D31)], appearance: .dark, grain: 0.35)
    /// Colourless frame that follows the system's light/dark setting; Arc periwinkle accent.
    public static let neutral = SpaceTheme(colors: [RGBA(hex: 0x8489FF)], appearance: .automatic, grain: 0.2,
                                           isNeutral: true, accent: RGBA(hex: 0x8489FF))
    public static let presets: [SpaceTheme] = [neutral, lavender, coral, sky, mint, sand, graphite]

    /// New Spaces start neutral (light/dark follows the system), each with its own accent.
    public static func newSpaceDefault(index: Int) -> SpaceTheme {
        var theme = SpaceTheme.neutral
        theme.accent = accents[index % accents.count]
        return theme
    }

    /// Accent swatches for neutral Spaces (Arc periwinkle first).
    public static let accents: [RGBA] = [0x8489FF, 0x3D7BF7, 0xA25BEF, 0xEC5FA7, 0xF2555A, 0xF59B42, 0xE8C43A, 0x3CC27A, 0x2EB5C0, 0x8E8E93]
        .map { RGBA(hex: $0) }
}
