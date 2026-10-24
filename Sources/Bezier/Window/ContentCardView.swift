import AppKit
import SwiftUI

/// The inset, rounded card that holds web content (8pt radius, theme-tinted hairline,
/// faint drop shadow). Tab switches re-parent the tab's live view here, never reload it.
final class ContentCardView: NSView {
    private let clip = NSView()
    private let wash = NSView()
    private let emptyView = NSView()
    private(set) weak var contentView: NSView?
    /// Split View: the pages sit edge to edge in the one card, with a draggable divider
    /// between each pair.
    private var panes: [NSView] = []
    private var dividers: [ResizeHandle] = []
    /// Each pane's share of the width (height when stacked), left to right or top to bottom.
    private var fractions: [CGFloat] = []
    private var stacked = false
    private var resizeStart: (fractions: [CGFloat], offset: CGFloat)?
    private var dividerColor: Color = .accentColor
    private(set) var paneContents: [NSView] = []
    private(set) var focusedPane = 0
    private var isKey = true
    var isSplit: Bool { !panes.isEmpty }
    static let minPaneWidth: CGFloat = 220
    static let minPaneHeight: CGFloat = 140
    /// A divider drag ended; the panes' new shares of the width.
    var onSplitResized: (([CGFloat]) -> Void)?
    /// Docked above the page when visible (Developer Mode bar).
    var toolbar: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let toolbar { clip.addSubview(toolbar, positioned: .below, relativeTo: wash) }
            needsLayout = true
        }
    }

    var toolbarHeight: CGFloat = 0 {
        didSet { if toolbarHeight != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        clip.wantsLayer = true
        clip.layer?.cornerRadius = Metrics.cardRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = Metrics.cardBorderWidth
        addSubview(clip)

        emptyView.wantsLayer = true
        clip.addSubview(emptyView)

        wash.wantsLayer = true
        wash.isHidden = true
        clip.addSubview(wash)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ palette: ThemePalette) {
        dividerColor = palette.accent
        for divider in dividers { divider.highlight = palette.accent }
        clip.layer?.borderColor = palette.cardHairline.cgColor
        emptyView.layer?.backgroundColor = (palette.isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 1, alpha: 0.55)).cgColor
        wash.layer?.backgroundColor = (palette.isDark ? NSColor(white: 0, alpha: 0.35) : NSColor(white: 1, alpha: 0.35)).cgColor
    }

    func show(_ view: NSView?) {
        if isSplit { tearDownSplit() }
        guard view !== contentView || view?.superview !== clip else { return }
        contentView?.removeFromSuperview()
        contentView = view
        if let view {
            view.frame = contentFrame
            view.autoresizingMask = []
            clip.addSubview(view, positioned: .below, relativeTo: wash)
        }
        emptyView.isHidden = view != nil
    }

    // MARK: Split View

    /// `widths`: each pane's saved share of the width (height when `stacked`); equal shares
    /// unless all are given.
    func showSplit(_ views: [NSView], focused: Int, widths: [Double?], stacked: Bool = false) {
        contentView?.removeFromSuperview()
        contentView = nil
        emptyView.isHidden = true
        while panes.count < views.count {
            let pane = NSView()
            pane.wantsLayer = true
            pane.layer?.masksToBounds = true
            // Under the dividers, which sit just below the wash.
            clip.addSubview(pane, positioned: .below, relativeTo: dividers.first ?? wash)
            panes.append(pane)
        }
        while panes.count > views.count { panes.removeLast().removeFromSuperview() }
        while dividers.count < views.count - 1 {
            let index = dividers.count
            let divider = ResizeHandle()
            divider.highlight = dividerColor
            divider.onBegin = { [weak self] in self?.beginResize() }
            divider.onDrag = { [weak self] delta in self?.resize(divider: index, by: delta) }
            divider.onEnd = { [weak self] in self?.endResize() }
            clip.addSubview(divider, positioned: .below, relativeTo: wash)
            dividers.append(divider)
        }
        while dividers.count > views.count - 1 { dividers.removeLast().removeFromSuperview() }
        self.stacked = stacked
        for divider in dividers { divider.isHorizontal = stacked }
        for (pane, view) in zip(panes, views) {
            for old in pane.subviews where old !== view { old.removeFromSuperview() }
            if view.superview !== pane {
                view.removeFromSuperview()
                view.autoresizingMask = [.width, .height]
                pane.addSubview(view)
            }
        }
        let saved = widths.compactMap { $0 }.filter { $0 > 0 }
        let total = saved.reduce(0, +)
        fractions = saved.count == views.count ? saved.map { CGFloat($0 / total) }
                                               : Array(repeating: 1 / CGFloat(views.count), count: views.count)
        paneContents = views
        focusedPane = min(focused, views.count - 1)
        needsLayout = true
    }

    func setFocusedPane(_ index: Int) {
        guard isSplit, panes.indices.contains(index) else { return }
        focusedPane = index
    }

    /// Pane under a point in window coordinates (none over a divider).
    func paneIndex(atWindowPoint point: NSPoint) -> Int? {
        guard !dividers.contains(where: { $0.bounds.contains($0.convert(point, from: nil)) }) else { return nil }
        return panes.firstIndex { $0.bounds.contains($0.convert(point, from: nil)) }
    }

    private func beginResize() {
        resizeStart = (fractions, 0)
    }

    /// Moves divider `index` by the drag so far, keeping both neighbours at least `minPaneWidth`.
    private func resize(divider index: Int, by delta: CGFloat) {
        guard var start = resizeStart, fractions.indices.contains(index + 1) else { return }
        start.offset += delta
        resizeStart = start
        let length = max(stacked ? clip.bounds.height : clip.bounds.width, 1)
        let pair = start.fractions[index] + start.fractions[index + 1]
        let minimum = min((stacked ? Self.minPaneHeight : Self.minPaneWidth) / length, pair / 2)
        let left = min(max(start.fractions[index] + start.offset / length, minimum), pair - minimum)
        fractions[index] = left
        fractions[index + 1] = pair - left
        needsLayout = true
    }

    private func endResize() {
        guard resizeStart != nil else { return }
        resizeStart = nil
        onSplitResized?(fractions)
    }

    private func tearDownSplit() {
        for pane in panes { pane.subviews.forEach { $0.removeFromSuperview() }; pane.removeFromSuperview() }
        for divider in dividers { divider.removeFromSuperview() }
        panes = []
        dividers = []
        fractions = []
        resizeStart = nil
        paneContents = []
    }

    private var contentFrame: NSRect {
        NSRect(x: 0, y: 0, width: clip.bounds.width, height: max(0, clip.bounds.height - toolbarHeight))
    }

    /// The key window's page floats a little: a soft shadow under the card. Background windows
    /// sit flat (Arc dims inactive windows so you notice which one has focus).
    func setKey(_ isKey: Bool) {
        self.isKey = isKey
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        layer?.shadowOpacity = isKey ? 0.2 : 0.06
        layer?.shadowRadius = isKey ? 7 : 2
        layer?.shadowOffset = CGSize(width: 0, height: isKey ? -2.5 : -1)
        CATransaction.commit()
    }

    /// The Command Bar washes the page behind it.
    func setWashed(_ washed: Bool) {
        wash.isHidden = !washed
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        emptyView.frame = clip.bounds
        wash.frame = clip.bounds
        toolbar?.frame = NSRect(x: 0, y: bounds.height - toolbarHeight, width: bounds.width, height: toolbarHeight)
        toolbar?.isHidden = toolbarHeight == 0
        contentView?.frame = contentFrame
        if isSplit && stacked {
            // Top to bottom (the card isn't flipped, so the first pane has the highest y).
            var top = bounds.height
            for (i, pane) in panes.enumerated() {
                let bottom = i == panes.count - 1 ? 0 : (top - fractions[i] * bounds.height).rounded()
                pane.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: top - bottom)
                pane.subviews.first?.frame = pane.bounds
                if dividers.indices.contains(i) {
                    dividers[i].frame = NSRect(x: 0, y: bottom - 4, width: bounds.width, height: 8)
                }
                top = bottom
            }
        } else if isSplit {
            var x: CGFloat = 0
            for (i, pane) in panes.enumerated() {
                let right = i == panes.count - 1 ? bounds.width : (x + fractions[i] * bounds.width).rounded()
                pane.frame = NSRect(x: x, y: 0, width: right - x, height: bounds.height)
                pane.subviews.first?.frame = pane.bounds
                if dividers.indices.contains(i) {
                    dividers[i].frame = NSRect(x: right - 4, y: 0, width: 8, height: bounds.height)
                }
                x = right
            }
        }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Metrics.cardRadius,
                                   cornerHeight: Metrics.cardRadius, transform: nil)
    }
}
