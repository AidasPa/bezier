import AppKit
import BezierCore
import SwiftUI

/// Arc's Space theme picker: appearance switch, a colour pad with 1–3 draggable handles,
/// add/remove stops, preset swatches, intensity, grain and glass (translucency). Every change previews live on the
/// whole window. Spec: references/design/design-language.md §3 "Theme picker".
struct ThemeEditor: View {
    let controller: BrowserWindowController
    let space: Space

    @State private var theme: SpaceTheme

    init(controller: BrowserWindowController, space: Space) {
        self.controller = controller
        self.space = space
        _theme = State(initialValue: space.theme)
    }

    /// Arc's Dec 2022 preset swatches (cream, pink, mauve, red, orange, yellow, mint, sky, slate).
    static let swatches: [RGBA] = [0xF4EEEA, 0xECB1C6, 0xAF89AB, 0xE97F81, 0xF49E75, 0xF5DC80, 0x82E7AC, 0x8FC5DE, 0x797B98]
        .map { RGBA(hex: $0) }

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: Binding(
                get: { theme.isNeutral },
                set: { neutral in
                    theme.isNeutral = neutral
                    // Neutral is about matching the system; default it to follow light/dark.
                    if neutral && theme.appearance == .light { theme.appearance = .automatic }
                }
            )) {
                Label("Colour", systemImage: "paintpalette").tag(false)
                Label("Neutral", systemImage: "circle.lefthalf.filled").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("", selection: $theme.appearance) {
                Label("Auto", systemImage: "sparkles").tag(SpaceTheme.Appearance.automatic)
                Label("Light", systemImage: "sun.max").tag(SpaceTheme.Appearance.light)
                Label("Dark", systemImage: "moon").tag(SpaceTheme.Appearance.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !theme.isNeutral {
            ColorPad(colors: $theme.colors)
                .frame(height: 170)

            HStack(spacing: 8) {
                Button { removeStop() } label: { Image(systemName: "minus") }
                    .disabled(theme.colors.count <= 1)
                Button { addStop() } label: { Image(systemName: "plus") }
                    .disabled(theme.colors.count >= 3)
                Spacer()
                ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                    Button { theme.colors = [swatch] } label: {
                        Circle().fill(swatch.color).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    }
                    .buttonStyle(PressableStyle(scale: 0.85))
                }
            }
            .controlSize(.small)
            }

            AccentRow(accent: $theme.accent)

            if !theme.isNeutral {
                LabeledSlider(title: "Intensity", symbol: "circle.lefthalf.filled", value: $theme.intensity, range: 0.15...1)
            }
            LabeledSlider(title: "Grain", symbol: "circle.dotted", value: $theme.grain, range: 0...1)
            LabeledSlider(title: "Glass", symbol: "square.on.square.dashed", value: $theme.translucency, range: 0...1)
        }
        .padding(16)
        .frame(width: 300)
        .onChange(of: theme) { _, new in controller.setTheme(new, for: space, animated: false) }
    }

    private func addStop() {
        guard let last = theme.colors.last else { return }
        var (h, s, b) = last.hsb
        h = (h + 0.12).truncatingRemainder(dividingBy: 1)
        s = max(0.25, s)
        theme.colors.append(RGBA(hue: h, saturation: s, brightness: b))
    }

    private func removeStop() {
        if theme.colors.count > 1 { theme.colors.removeLast() }
    }
}

/// Highlight colour: Auto (derived from the theme) or a fixed swatch/custom colour.
private struct AccentRow: View {
    @Binding var accent: RGBA?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accent").font(.system(size: 12, weight: .medium))
            HStack(spacing: 5) {
                Button { accent = nil } label: {
                    Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 17, height: 17)
                        .background(Circle().strokeBorder(Color.primary.opacity(accent == nil ? 0.7 : 0.2), lineWidth: accent == nil ? 1.5 : 0.5))
                }
                .buttonStyle(PressableStyle(scale: 0.85))
                .help("Automatic: matches the theme colour")
                ForEach(Array(SpaceTheme.accents.enumerated()), id: \.offset) { _, swatch in
                    Button { accent = swatch } label: {
                        Circle().fill(swatch.color).frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(accent == swatch ? 0.7 : 0), lineWidth: 1.5).padding(-2.5))
                    }
                    .buttonStyle(PressableStyle(scale: 0.8))
                }
                Spacer(minLength: 0)
                ColorPicker("", selection: Binding(
                    get: { accent?.color ?? .accentColor },
                    set: { color in
                        if let c = NSColor(color).usingColorSpace(.sRGB) {
                            accent = RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                        }
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.mini)
                .help("Custom colour")
            }
        }
    }
}

/// Hue (x) × vividness (y) field; one handle per colour, the first one larger.
private struct ColorPad: View {
    @Binding var colors: [RGBA]

    private static let minSat = 0.08
    private static let maxSat = 0.85

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.75, brightness: 0.97) },
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.clear, .white.opacity(0.92)], startPoint: .top, endPoint: .bottom)))
                    .overlay(DotGrid().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    let point = position(of: color, in: size)
                    Circle()
                        .fill(color.color)
                        .frame(width: index == 0 ? 30 : 20, height: index == 0 ? 30 : 20)
                        .overlay(Circle().strokeBorder(.white, lineWidth: index == 0 ? 4 : 3))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .position(point)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            colors[index] = pickColor(at: drag.location, in: size, brightness: color.hsb.b)
                        })
                }
            }
        }
    }

    private func position(of color: RGBA, in size: CGSize) -> CGPoint {
        let (h, s, _) = color.hsb
        let y = 1 - (s - Self.minSat) / (Self.maxSat - Self.minSat)
        return CGPoint(x: h * size.width, y: min(1, max(0, y)) * size.height)
    }

    private func pickColor(at point: CGPoint, in size: CGSize, brightness: Double) -> RGBA {
        let x = min(1, max(0, point.x / size.width))
        let y = min(1, max(0, point.y / size.height))
        let saturation = Self.maxSat - y * (Self.maxSat - Self.minSat)
        return RGBA(hue: x, saturation: saturation, brightness: max(0.85, brightness))
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 12
            for x in stride(from: step / 2, to: size.width, by: step) {
                for y in stride(from: step / 2, to: size.height, by: step) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.white.opacity(0.35)))
                }
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 12, weight: .medium)).frame(width: 62, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

/// Emoji icon picker for Spaces (Arc: "Change Space Icon").
struct IconPicker: View {
    let current: String?
    let onPick: (String?) -> Void

    @State private var custom = ""

    static let emoji = [
        "🏡", "💼", "🚀", "🎨", "📚", "🧪", "🎮", "🎵", "✈️", "🍳", "💡", "🔥",
        "🌱", "🌊", "⭐️", "❤️", "🧠", "📈", "🛠️", "🗂️", "📝", "🎓", "🏋️", "🧘",
        "🐶", "🐱", "🦊", "🐼", "🌙", "☀️", "🌈", "⚡️", "🍀", "🍕", "☕️", "🎬",
        "🏝️", "🏔️", "🌍", "🛒", "💰", "🧾", "📷", "🎧", "🖥️", "📱", "🔒", "👾",
    ]

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.emoji, id: \.self) { emoji in
                    Button { onPick(emoji) } label: {
                        Text(emoji).font(.system(size: 18))
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(emoji == current ? Color.accentColor.opacity(0.25) : .clear))
                    }
                    .buttonStyle(PressableStyle(scale: 0.85))
                }
            }
            HStack {
                TextField("Any emoji", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let first = custom.first { onPick(String(first)) } }
                Button("Remove") { onPick(nil) }
                    .disabled(current == nil)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280)
    }
}

extension RGBA {
    init(hue: Double, saturation: Double, brightness: Double) {
        let c = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.sRGB)!
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    var hsb: (h: Double, s: Double, b: Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return (Double(h), Double(s), Double(b))
    }
}
