import SwiftUI

/// The welcome wordmark, set over a pen-tool curve. The pen lays a straight segment between two
/// anchors, revealing the word in its wake; then the handles pull out and the segment bends into
/// a swash. The handles keep drifting. Drag one to bend the curve; let go and it springs back.
struct BezierMark: View {
    static let size = CGSize(width: 600, height: 226)
    /// Room around the frame for the glow and for handles dragged past the edge.
    private static let overflow: CGFloat = 90
    private static let baseline: CGFloat = 108
    private static let anchors = (CGPoint(x: 56, y: baseline + 22), CGPoint(x: 544, y: baseline + 10))
    private static let handles = (CGVector(dx: 150, dy: 48), CGVector(dx: -150, dy: 42))

    @State private var start = Date.now
    @State private var grab: Grab?
    @State private var release: Release?
    @State private var hovered: Int?

    private struct Grab { var handle: Int; var carried: CGSize; var translation: CGSize }
    private struct Release { var handle: Int; var offset: CGSize; var at: Date }
    private struct Curve { var p0, h0, h1, p3: CGPoint }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                context.translateBy(x: Self.overflow, y: Self.overflow)
                draw(&context, now: timeline.date)
            }
            .frame(width: Self.size.width + Self.overflow * 2, height: Self.size.height + Self.overflow * 2)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .contentShape(Rectangle())
        .gesture(handleDrag)
        .onContinuousHover { phase in
            guard case .active(let point) = phase else { hovered = nil; return }
            hovered = nearestHandle(to: point, now: .now)
        }
        .onAppear { start = .now }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, now: Date) {
        let t = now.timeIntervalSince(start)
        let curve = curve(at: now)
        let drawn = Self.easeInOut(Self.clamp((t - 0.3) / 1.0))
        let head = Self.point(on: curve, at: drawn)

        // The word, revealed just ahead of the pen.
        let word = context.resolve(Text("Bezier").font(.system(size: 108, weight: .bold)).tracking(-3.2))
        context.drawLayer { layer in
            layer.draw(word, at: CGPoint(x: Self.size.width / 2, y: Self.baseline - 38 + 10 * (1 - drawn)), anchor: .center)
            layer.blendMode = .destinationIn
            let edge = head.x + 40
            layer.fill(Path(CGRect(x: -Self.overflow, y: -Self.overflow, width: Self.size.width + Self.overflow * 2,
                                   height: Self.size.height + Self.overflow * 2)),
                       with: .linearGradient(Gradient(colors: [.black, .clear]),
                                             startPoint: CGPoint(x: edge - 120, y: 0), endPoint: CGPoint(x: edge, y: 0)))
        }

        // Handles, under the curve.
        let extend = Self.clamp((t - 1.35) / 0.25)
        if extend > 0 {
            for (anchor, knob) in [(curve.p0, curve.h0), (curve.p3, curve.h1)] {
                var line = Path()
                line.move(to: anchor)
                line.addLine(to: knob)
                context.stroke(line, with: .color(OnboardingInk.violet.opacity(0.55 * extend)), lineWidth: 1)
            }
        }

        // The curve, drawn as far as the pen has got: a soft glow, then the stroke.
        let part = Self.split(curve, at: drawn)
        var path = Path()
        path.move(to: part.p0)
        path.addCurve(to: part.p3, control1: part.h0, control2: part.h1)
        let ink = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [OnboardingInk.blue, OnboardingInk.violet, OnboardingInk.purple]),
            startPoint: curve.p0, endPoint: curve.p3)
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 9))
            glow.opacity = 0.4
            glow.stroke(path, with: ink, style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        context.stroke(path, with: ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))

        // Anchors pop in as the pen reaches them; knobs ride the ends of the handles.
        drawAnchor(&context, at: curve.p0, scale: Self.backOut(Self.clamp((t - 0.25) / 0.35)))
        drawAnchor(&context, at: curve.p3, scale: Self.backOut(Self.clamp((t - 1.25) / 0.35)))
        if extend > 0 {
            drawKnob(&context, at: curve.h0, scale: extend, hot: hovered == 0 || grab?.handle == 0)
            drawKnob(&context, at: curve.h1, scale: extend, hot: hovered == 1 || grab?.handle == 1)
        }
    }

    private func drawAnchor(_ context: inout GraphicsContext, at point: CGPoint, scale: Double) {
        guard scale > 0 else { return }
        let side = 10 * scale
        let square = Path(roundedRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), cornerRadius: 2)
        context.fill(square, with: .color(.white))
        context.stroke(square, with: .color(OnboardingInk.violet), lineWidth: 1.5)
    }

    private func drawKnob(_ context: inout GraphicsContext, at point: CGPoint, scale: Double, hot: Bool) {
        let radius = (hot ? 7 : 5) * scale
        let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: OnboardingInk.violet.opacity(0.45), radius: 4, y: 1))
            layer.fill(dot, with: .color(OnboardingInk.violet))
        }
        context.stroke(dot, with: .color(.white), lineWidth: 2)
    }

    // MARK: Geometry

    private func curve(at now: Date) -> Curve {
        let t = now.timeIntervalSince(start)
        // Handles pull out (with a little overshoot) once the segment is laid, then start drifting.
        let extend = Self.backOut(Self.clamp((t - 1.35) / 0.6))
        let drift = Self.smoothstep(1.8, 3.6, t)
        func handle(_ v: CGVector, angle: Double, stretch: Double) -> CGVector {
            let a = angle * drift, s = (1 + stretch * drift) * extend
            return CGVector(dx: (v.dx * cos(a) - v.dy * sin(a)) * s, dy: (v.dx * sin(a) + v.dy * cos(a)) * s)
        }
        let (p0, p3) = Self.anchors
        let d0 = handle(Self.handles.0, angle: 0.18 * sin(t * 0.8), stretch: 0.1 * sin(t * 0.6 + 1))
        let d1 = handle(Self.handles.1, angle: 0.2 * sin(t * 0.7 + 2), stretch: 0.1 * sin(t * 0.9))
        let o0 = offset(of: 0, now: now), o1 = offset(of: 1, now: now)
        return Curve(p0: p0, h0: CGPoint(x: p0.x + d0.dx + o0.width, y: p0.y + d0.dy + o0.height),
                     h1: CGPoint(x: p3.x + d1.dx + o1.width, y: p3.y + d1.dy + o1.height), p3: p3)
    }

    /// How far the user has pulled a handle from where it would be: the live drag, or a released
    /// drag springing back.
    private func offset(of handle: Int, now: Date) -> CGSize {
        if let grab, grab.handle == handle {
            return CGSize(width: grab.carried.width + grab.translation.width, height: grab.carried.height + grab.translation.height)
        }
        if let release, release.handle == handle {
            let k = Self.springBack(now.timeIntervalSince(release.at))
            return CGSize(width: release.offset.width * k, height: release.offset.height * k)
        }
        return .zero
    }

    private func nearestHandle(to point: CGPoint, now: Date) -> Int? {
        guard now.timeIntervalSince(start) > 1.6 else { return nil }
        let c = curve(at: now)
        let d0 = hypot(c.h0.x - point.x, c.h0.y - point.y), d1 = hypot(c.h1.x - point.x, c.h1.y - point.y)
        let (index, distance) = d0 <= d1 ? (0, d0) : (1, d1)
        return distance < 22 ? index : nil
    }

    private var handleDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grab != nil {
                    grab?.translation = value.translation
                    return
                }
                let now = Date.now
                guard let handle = nearestHandle(to: value.startLocation, now: now) else { return }
                let carried = offset(of: handle, now: now)
                if release?.handle == handle { release = nil }
                grab = Grab(handle: handle, carried: carried, translation: value.translation)
            }
            .onEnded { _ in
                guard let grab else { return }
                let now = Date.now
                release = Release(handle: grab.handle, offset: offset(of: grab.handle, now: now), at: now)
                self.grab = nil
            }
    }

    private static func point(on c: Curve, at t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
        return CGPoint(x: a * c.p0.x + b * c.h0.x + d * c.h1.x + e * c.p3.x,
                       y: a * c.p0.y + b * c.h0.y + d * c.h1.y + e * c.p3.y)
    }

    /// The part of the curve from its start to `t` (de Casteljau).
    private static func split(_ c: Curve, at t: Double) -> Curve {
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        let ab = lerp(c.p0, c.h0), bc = lerp(c.h0, c.h1), cd = lerp(c.h1, c.p3)
        let abc = lerp(ab, bc), bcd = lerp(bc, cd)
        return Curve(p0: c.p0, h0: ab, h1: abc, p3: lerp(abc, bcd))
    }

    // MARK: Easing

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    private static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

    private static func backOut(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return x <= 0 ? 0 : 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// A released handle's way home: an underdamped spring from 1 to 0.
    private static func springBack(_ t: Double) -> Double {
        let omega = 11.0, zeta = 0.32
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
    }
}
