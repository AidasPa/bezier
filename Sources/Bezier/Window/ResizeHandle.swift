import AppKit
import SwiftUI

/// Draggable strip on an edge: the sidebar/card boundary, or between Split View panes.
/// Hovering or dragging lights up the edge as a rounded line, inset from its ends.
final class ResizeHandle: NSView {
    /// A horizontal edge (between stacked panes) dragged up and down; `onDrag` then reports
    /// downward movement as positive.
    var isHorizontal = false {
        didSet { needsLayout = true; window?.invalidateCursorRects(for: self) }
    }
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var highlight: Color = .accentColor { didSet { line.backgroundColor = NSColor(highlight).cgColor } }
    private var last: CGFloat = 0
    private var hovering = false
    private var dragging = false
    private let line = CALayer()
    private static let verticalPadding: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.cornerRadius = 1.5
        line.opacity = 0
        line.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pad = Self.verticalPadding
        line.frame = isHorizontal
            ? NSRect(x: pad, y: bounds.midY - 1.5, width: max(0, bounds.width - pad * 2), height: 3)
            : NSRect(x: bounds.midX - 1.5, y: pad, width: 3, height: max(0, bounds.height - pad * 2))
        CATransaction.commit()
    }

    /// Edges drag straight away, even in a background window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // Over a web page, the page sets its own cursor as the pointer moves; claim it back.
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    private var cursor: NSCursor { isHorizontal ? .resizeUpDown : .resizeLeftRight }

    private func position(_ event: NSEvent) -> CGFloat { isHorizontal ? -event.locationInWindow.y : event.locationInWindow.x }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateLine() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateLine() }

    override func mouseDown(with event: NSEvent) {
        last = position(event)
        dragging = true
        updateLine()
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = position(event)
        onDrag?(now - last)
        last = now
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        updateLine()
        onEnd?()
    }

    private func updateLine() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(dragging || hovering ? 0.12 : 0.3)
        line.opacity = dragging ? 0.95 : (hovering ? 0.6 : 0)
        CATransaction.commit()
    }
}
