import AppKit
import MetalKit
import simd

/// Onboarding background: liquid marbling, white at the top (where the words sit) and flowing
/// into crisp bands below: periwinkle, blue, bright purple shading to violet, deep purple, with
/// dark veins and white threads along the band edges. Blue on the left, purple on the right.
enum OnboardingShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;   // drawable pixels
        float2 cursor;       // smoothed pointer, uv (0,0 top-left)
        float  time;
        float  stage;        // onboarding step, springing between whole numbers
        float  reveal;       // 0…1 while onboarding turns into the browser
        float  hover;        // pointer presence 0…1
    };

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut onboardingVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    float3 hex(uint v) { return float3((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) / 255.0; }

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), w.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), w.x), w.y);
    }

    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        const float2x2 m = float2x2(0.8, 0.6, -0.6, 0.8);
        for (int i = 0; i < 4; i++) { v += a * noise(p); p = m * p * 2.03 + 11.7; a *= 0.5; }
        return v;
    }

    // Anti-aliased step up at a band edge.
    float band(float v, float edge, float w) { return smoothstep(edge - w, edge + w, v); }
    // A thin line along a band edge.
    float seam(float v, float edge, float w, float width) { return 1.0 - smoothstep(0.0, w * 1.5 + width, abs(v - edge)); }

    fragment float4 onboardingFragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / u.resolution.y;
        float t = u.time * 0.05;
        float2 p = float2(uv.x * aspect, uv.y) * 0.9;
        float2 c = float2(u.cursor.x * aspect, u.cursor.y) * 0.9;
        p += 0.12 * u.hover * (p - c) * exp(-dot(p - c, p - c) * 6.0);      // the pointer stirs it
        float2 q = float2(fbm(p + t), fbm(p + float2(5.2, 1.3) - t));
        float2 r = float2(fbm(p + 3.0 * q + float2(1.7, 9.2) + 1.5 * t), fbm(p + 3.0 * q + float2(8.3, 2.8) - t));
        float v = fbm(p + 3.4 * r + u.stage * 0.15) + (uv.y - 0.64) * 1.7;
        float w = fwidth(v) * 1.2;
        float side = saturate(uv.x * 1.15 + (r.x - 0.5) * 0.9 - 0.08);    // 0 left (blue) … 1 right (purple)

        float3 col = float3(1.0);
        col = mix(col, mix(hex(0xE2E8FF), hex(0xEDE3FF), side), band(v, 0.30, w));
        col = mix(col, mix(hex(0x2F5BFF), hex(0x4F5DFF), side), band(v, 0.39, w));
        col = mix(col, mix(hex(0x5AA0FF), hex(0xB24DFF), side), band(v, 0.48, w));
        col = mix(col, mix(hex(0x4338E8), hex(0x7B2CFF), side), band(v, 0.58, w));
        col = mix(col, hex(0x22085C), band(v, 0.69, w));
        col = mix(col, hex(0x22085C), 0.85 * seam(v, 0.39, w, 0.004));    // dark vein
        col = mix(col, float3(1.0), 0.9 * seam(v, 0.48, w, 0.003));       // white thread

        col = mix(col, float3(1.0), u.reveal);
        col += (hash21(in.position.xy) - 0.5) * 0.012;                       // a little grain against banding
        return float4(saturate(col), 1.0);
    }
    """#
}

/// Renders `OnboardingShader` at the display's refresh rate. `stage` (the onboarding step)
/// springs to each new value so the marbling shifts between steps; `reveal` fades it to white.
/// A few rows of pixels under `sampleRect` are read back now and then and reported through
/// `onSampleLuminance`, so controls over the background can pick light or dark styling.
@MainActor
final class OnboardingShaderView: MTKView, MTKViewDelegate {
    private struct Uniforms {
        var resolution: SIMD2<Float> = .zero
        var cursor: SIMD2<Float> = [0.5, 0.5]
        var time: Float = 0
        var stage: Float = 0
        var reveal: Float = 0
        var hover: Float = 0
    }

    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var uniforms = Uniforms()
    private let start = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()
    private var target: SIMD2<Float> = [0.5, 0.5]
    private var velocity: SIMD2<Float> = .zero
    private var pointerInside = false
    private var stageVelocity: Float = 0
    private var frameCount = 0
    private var samples: MTLBuffer?
    private var sampleShape = (width: 0, rows: 0)

    var reveal: Float = 0
    /// The onboarding step's index.
    var stage: Float = 0
    /// Region to report the brightness of (view coordinates, top-left origin).
    var sampleRect: CGRect = .zero
    /// Average luminance (0…1) under `sampleRect`, a few times a second.
    var onSampleLuminance: ((Float) -> Void)?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = false                 // the sample rows are blitted out of the drawable
        preferredFramesPerSecond = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        delegate = self
        guard let device else { return }
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: OnboardingShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "onboardingVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "onboardingFragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Onboarding shader failed to compile: \(error)")
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        target = [Float(p.x / bounds.width), Float(1 - p.y / bounds.height)]
        pointerInside = true
    }

    override func mouseExited(with event: NSEvent) { pointerInside = false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(1.0 / 20, now - lastFrame))
        lastFrame = now

        // Pointer: a critically damped spring, so the marbling glides after it.
        let stiffness: Float = 18
        velocity += (stiffness * (target - uniforms.cursor) - 2 * stiffness.squareRoot() * velocity) * dt
        uniforms.cursor += velocity * dt
        uniforms.hover += ((pointerInside ? 1 : 0) - uniforms.hover) * min(1, dt * 3)

        // Step changes: a soft spring with a little overshoot.
        let k: Float = 9
        stageVelocity += (k * (stage - uniforms.stage) - 2 * 0.8 * k.squareRoot() * stageVelocity) * dt
        uniforms.stage += stageVelocity * dt

        uniforms.time = Float(now - start)
        uniforms.reveal = reveal
        uniforms.resolution = [Float(drawableSize.width), Float(drawableSize.height)]

        guard let pipeline, let queue, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        frameCount += 1
        if frameCount % 12 == 0 { sample(drawable.texture, in: buffer) }
        buffer.present(drawable)
        buffer.commit()
    }

    /// Copies three rows across `sampleRect` out of the frame and reports their mean luminance.
    private func sample(_ texture: MTLTexture, in buffer: MTLCommandBuffer) {
        guard onSampleLuminance != nil, sampleRect.width > 0, bounds.width > 0, let device else { return }
        let scale = drawableSize.width / bounds.width
        let x = max(0, Int(sampleRect.minX * scale))
        let width = min(texture.width - x, Int(sampleRect.width * scale))
        let ys = [0.25, 0.5, 0.75].map { min(texture.height - 1, Int((sampleRect.minY + sampleRect.height * $0) * scale)) }
        guard width > 0 else { return }
        if samples == nil || sampleShape != (width, ys.count) {
            samples = device.makeBuffer(length: width * ys.count * 4, options: .storageModeShared)
            sampleShape = (width, ys.count)
        }
        guard let samples, let blit = buffer.makeBlitCommandEncoder() else { return }
        for (row, y) in ys.enumerated() {
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: width, height: 1, depth: 1), to: samples,
                      destinationOffset: row * width * 4, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * 4)
        }
        blit.endEncoding()
        buffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reportLuminance() } }
        }
    }

    private func reportLuminance() {
        guard let samples else { return }
        let count = sampleShape.width * sampleShape.rows
        let bytes = samples.contents().bindMemory(to: UInt8.self, capacity: count * 4)
        var total: Float = 0
        for i in stride(from: 0, to: count, by: 4) {        // every 4th pixel is plenty
            let b = Float(bytes[i * 4]), g = Float(bytes[i * 4 + 1]), r = Float(bytes[i * 4 + 2])
            total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        onSampleLuminance?(total / Float((count + 3) / 4))
    }
}
