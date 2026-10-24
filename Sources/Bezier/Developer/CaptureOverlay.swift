import AppKit
import SwiftUI

/// ⇧⌘2 Capture: drag over the page to capture that area, or use the bar to capture what's
/// visible or the whole page. Escape cancels.
final class CaptureOverlayView: NSView {
    enum Choice { case area(CGRect), visible, fullPage, cancel }

    var onChoice: ((Choice) -> Void)?
    private let dim = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let bar: NSHostingView<CaptureBar>
    private var start: CGPoint?
    private var selection: CGRect? { didSet { redraw() } }

    override init(frame: NSRect) {
        bar = NSHostingView(rootView: CaptureBar())
        super.init(frame: frame)
        wantsLayer = true
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        layer?.addSublayer(dim)
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        layer?.addSublayer(outline)
        bar.rootView = CaptureBar(choose: { [weak self] in self?.onChoice?($0) })
        bar.sizingOptions = [.intrinsicContentSize]
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let size = bar.fittingSize
        bar.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: 18, width: size.width, height: size.height)
        redraw()
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let selection { path.addRect(selection) }
        dim.path = path
        dim.frame = bounds
        outline.path = selection.map { CGPath(rect: $0.insetBy(dx: -0.75, dy: -0.75), transform: nil) }
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        addCursorRect(bar.frame, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            .intersection(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        guard let selection, selection.width > 6, selection.height > 6 else { self.selection = nil; return }
        onChoice?(.area(selection))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onChoice?(.cancel) } else { super.keyDown(with: event) }
    }

    func animateIn() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }
}

private struct CaptureBar: View {
    var choose: (CaptureOverlayView.Choice) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 4) {
            Text("Drag to capture an area").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 8)
            Divider().frame(height: 18)
            button("Visible", symbol: "rectangle.dashed") { choose(.visible) }
            button("Full Page", symbol: "arrow.up.and.down.text.horizontal") { choose(.fullPage) }
            Divider().frame(height: 18)
            button("Cancel", symbol: nil) { choose(.cancel) }
        }
        .padding(6)
        .modifier(GlassPanel(cornerRadius: 20))
        .padding(30)
    }

    private func button(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
    }
}
