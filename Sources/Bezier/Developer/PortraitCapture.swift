import AppKit
import BezierCore
import SwiftUI

/// Arc's "Capture in Portrait Mode": the page as a rounded card with a soft shadow on a gradient
/// backdrop. Defaults to the Space's own colours; the slider picks any hue, the dice shuffles.
struct PortraitCaptureView: View {
    let controller: BrowserWindowController

    @State private var page: NSImage?
    @State private var hue = 0.95
    @State private var useSpaceColors = true

    private var background: [NSColor] {
        useSpaceColors ? PortraitRenderer.spaceBackground(controller.state.palette) : PortraitRenderer.hueBackground(hue)
    }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                guard let page else { return }
                controller.savePortrait(PortraitRenderer.render(page: page, background: background))
            } label: {
                Text("Capture in Portrait Mode").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(page == nil)

            ZStack {
                LinearGradient(colors: background.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                if let page {
                    Image(nsImage: page)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        .padding(22)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 236, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: hue)

            HStack(spacing: 10) {
                Button { useSpaceColors = true } label: {
                    Circle()
                        .fill(LinearGradient(colors: PortraitRenderer.spaceBackground(controller.state.palette).map { Color(nsColor: $0) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(useSpaceColors ? 0.6 : 0.15), lineWidth: useSpaceColors ? 2 : 0.5))
                }
                .buttonStyle(PressableStyle(scale: 0.85))
                .help("Space colours")
                HueSlider(hue: Binding(get: { hue }, set: { hue = $0; useSpaceColors = false }))
                Button { hue = Double.random(in: 0...1); useSpaceColors = false } label: {
                    Image(systemName: "dice").font(.system(size: 13))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(PressableStyle(scale: 0.85))
                .help("Surprise me")
            }
        }
        .padding(14)
        .frame(width: 264)
        .task { page = await controller.selectedContent?.snapshot() }
    }
}

/// Rainbow track with a white capsule thumb (Arc's colour slider).
private struct HueSlider: View {
    @Binding var hue: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: (0...10).map { Color(hue: Double($0) / 10, saturation: 0.6, brightness: 1) },
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: 20, height: 20)
                    .offset(x: hue * (geo.size.width - 20))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                hue = min(1, max(0, (drag.location.x - 10) / (geo.size.width - 20)))
            })
        }
        .frame(height: 22)
    }
}

enum PortraitRenderer {
    static func hueBackground(_ hue: Double) -> [NSColor] {
        [NSColor(hue: hue, saturation: 0.55, brightness: 1, alpha: 1),
         NSColor(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.98, alpha: 1)]
    }

    static func spaceBackground(_ palette: ThemePalette) -> [NSColor] {
        let colors = palette.frameColors
        return colors.count > 1 ? colors : [colors[0], colors[0].blended(withFraction: 0.25, of: .white) ?? colors[0]]
    }

    /// The page on a gradient with ~8% padding, rounded corners and a soft shadow, at 2x.
    static func render(page: NSImage, background: [NSColor]) -> NSImage {
        let size = page.size
        let pad = (max(size.width, size.height) * 0.08).rounded()
        let canvas = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: background)?.draw(in: NSRect(origin: .zero, size: canvas), angle: -35)

        let card = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        let radius = max(8, size.width * 0.012)
        let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = pad * 0.45
        shadow.shadowOffset = NSSize(width: 0, height: -pad * 0.12)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        page.draw(in: card)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: canvas)
        image.addRepresentation(rep)
        return image
    }
}
