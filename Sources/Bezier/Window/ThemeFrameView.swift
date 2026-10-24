import AppKit

/// The coloured "room" behind everything. On macOS 26 it's real Liquid Glass tinted with the
/// Space colour (the desktop refracts through it); earlier systems get a behind-window blur.
/// On top: the Space gradient and a film-grain overlay. The theme's translucency sets how much
/// glass shows. Arc draws this with a Metal shader (WindowThemeUI.metallib).
final class ThemeFrameView: NSView {
    private let backdrop: NSView
    /// Glass pieces: one for a plain frame; four (left, top, bottom, right) merged in a container
    /// when there's a `cutout`.
    private var glassPieces: [NSView] = []
    private let tint = ThemeTintView()
    private let usesGlass: Bool
    /// Floating panels (the slid-out sidebar) sit over the page and use the lighter tint.
    private let isFloating: Bool

    /// The part of the frame covered by the page card. Glass is kept only where it shows (the
    /// sidebar and the margins), so scrolling the page doesn't make the system re-render glass
    /// under the whole window every frame. Set inside the layout pass so it animates with it.
    var cutout: NSRect? {
        didSet { if cutout != oldValue { layoutBackdrop() } }
    }
    /// How far each glass piece reaches under the card, hiding the seams and the card's corners.
    private static let overlap: CGFloat = 24

    init(cornerRadius: CGFloat = 0, floating: Bool = false) {
        isFloating = floating
        if #available(macOS 26.0, *) {
            func piece() -> NSGlassEffectView {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.cornerRadius = cornerRadius
                return glass
            }
            if cornerRadius > 0 {
                let glass = piece()
                backdrop = glass
                glassPieces = [glass]
            } else {
                let container = NSGlassEffectContainerView()
                let content = NSView()
                glassPieces = (0..<4).map { _ in piece() }
                glassPieces.forEach(content.addSubview)
                container.contentView = content
                backdrop = container
            }
            usesGlass = true
        } else {
            let blur = NSVisualEffectView()
            blur.blendingMode = .behindWindow
            blur.material = .sidebar
            blur.state = .followsWindowActiveState
            backdrop = blur
            usesGlass = false
        }
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(backdrop)
        addSubview(tint)
        if cornerRadius > 0 {
            tint.layer?.cornerRadius = cornerRadius
            tint.layer?.cornerCurve = .continuous
            tint.layer?.masksToBounds = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    func apply(_ palette: ThemePalette, animated: Bool) {
        backdrop.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        if #available(macOS 26.0, *) {
            for case let glass as NSGlassEffectView in glassPieces {
                glass.tintColor = isFloating ? palette.floatingGlassTint : palette.glassTint
            }
        }
        let gradient = usesGlass ? (isFloating ? palette.floatingGradientOpacity : palette.glassGradientOpacity) : palette.tintOpacity
        tint.apply(palette, gradientOpacity: gradient, grainScale: isFloating ? 0.5 : 1, animated: animated)
    }

    override func layout() {
        super.layout()
        tint.frame = bounds
        layoutBackdrop()
    }

    private func layoutBackdrop() {
        backdrop.frame = bounds
        guard glassPieces.count == 4 else { glassPieces.first?.frame = bounds; return }
        if #available(macOS 26.0, *) { (backdrop as? NSGlassEffectContainerView)?.contentView?.frame = backdrop.bounds }
        let b = bounds
        guard let card = cutout?.insetBy(dx: Self.overlap, dy: Self.overlap), card.width > 0, card.height > 0 else {
            glassPieces[0].frame = b
            glassPieces.dropFirst().forEach { $0.frame = .zero }
            return
        }
        glassPieces[0].frame = NSRect(x: 0, y: 0, width: card.minX, height: b.height)
        glassPieces[1].frame = NSRect(x: 0, y: card.maxY, width: b.width, height: b.maxY - card.maxY)
        glassPieces[2].frame = NSRect(x: 0, y: 0, width: b.width, height: card.minY)
        glassPieces[3].frame = NSRect(x: card.maxX, y: 0, width: b.width - card.maxX, height: b.height)
    }
}

/// Gradient + grain, layer-hosted for cheap implicit animation of colours and opacity.
private final class ThemeTintView: NSView {
    private let gradient = CAGradientLayer()
    private let grain = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)
        grain.backgroundColor = NSColor(patternImage: Self.noiseImage).cgColor
        layer?.addSublayer(grain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ palette: ThemePalette, gradientOpacity: Float, grainScale: Float, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Motion.themeCrossfade : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setDisableActions(!animated)
        var colors = palette.frameColors.map(\.cgColor)
        if colors.count == 1 { colors.append(colors[0]) }
        gradient.colors = colors
        gradient.opacity = gradientOpacity
        grain.opacity = palette.grainOpacity * grainScale
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        grain.frame = bounds
        CATransaction.commit()
    }

    /// 128pt tile of monochrome noise at 2x, generated once.
    private static let noiseImage: NSImage = {
        let side = 256
        var generator = SystemRandomNumberGenerator()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: side * 2, bitsPerPixel: 16)!
        let data = rep.bitmapData!
        for i in 0..<(side * side) {
            let v = UInt8.random(in: 0...255, using: &generator)
            // Half the grains lighten, half darken, each with random strength.
            data[i * 2] = v > 127 ? 255 : 0
            data[i * 2 + 1] = UInt8(min(255, abs(Int(v) - 128) * 2))
        }
        rep.size = NSSize(width: side / 2, height: side / 2)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }()
}
