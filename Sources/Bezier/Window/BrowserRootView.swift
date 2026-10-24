import AppKit
import SwiftUI

/// Lays out the window: theme frame (full bleed), content card, the sidebar (docked into the
/// frame, or floating as a rounded panel when hidden and revealed from the left edge), the
/// resize handle and the toast overlay. Frames are computed here, not with Auto Layout, so the
/// sidebar transitions animate as one implicit-animation pass.
final class BrowserRootView: NSView {
    let themeFrame = ThemeFrameView()
    let card = ContentCardView()
    let sidebarHost: NSView
    let floatingBackground = FloatingSidebarBackground()
    private let resizeHandle = ResizeHandle()
    private let edgeTrigger = EdgeTriggerView()
    private let toastHost: NSView
    private let findHost: NSView
    private let switcherHost: NSHostingView<TabSwitcherView>
    private let state: WindowState

    /// Called when the pointer hits the left edge (reveal) or leaves the floating sidebar (hide).
    var onEdgeHover: (() -> Void)?
    var onFloatingExit: (() -> Void)?

    init(state: WindowState, sidebar: some View) {
        self.state = state
        let host = FirstMouseHostingView(rootView: sidebar)
        host.safeAreaRegions = []
        sidebarHost = host
        let toast = PassthroughHostingView(rootView: ToastOverlay(center: state.toasts))
        toast.safeAreaRegions = []
        toastHost = toast
        let find = NSHostingView(rootView: FindBar(model: state.find))
        find.safeAreaRegions = []
        find.sizingOptions = []
        find.isHidden = true
        findHost = find
        switcherHost = NSHostingView(rootView: TabSwitcherView(model: state.switcher))
        switcherHost.safeAreaRegions = []
        switcherHost.sizingOptions = []
        switcherHost.isHidden = true
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(themeFrame)
        addSubview(card)
        addSubview(floatingBackground)
        addSubview(sidebarHost)
        addSubview(resizeHandle)
        addSubview(edgeTrigger)
        addSubview(toastHost)
        addSubview(findHost)
        addSubview(switcherHost)
        resizeHandle.onDrag = { [weak self] delta in self?.resizeSidebar(by: delta) }
        resizeHandle.onEnd = { [weak self] in self?.state.persistSidebarWidth() }
        edgeTrigger.onEnter = { [weak self] in self?.onEdgeHover?() }
        floatingBackground.onExit = { [weak self] in self?.onFloatingExit?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func apply(_ palette: ThemePalette) {
        floatingBackground.apply(palette)
        card.apply(palette)
        resizeHandle.highlight = palette.accent
    }

    // Backstop for auto-hiding the floating sidebar: any pointer movement outside it (or leaving
    // the window) hides it, even if its own tracking area missed the exit.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard state.sidebarRevealed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !sidebarFrame.insetBy(dx: -14, dy: -14).contains(point) { onFloatingExit?() }
    }

    override func mouseExited(with event: NSEvent) {
        if state.sidebarRevealed { onFloatingExit?() }
    }

    /// Sidebar frame in this view's coordinates for the current state.
    var sidebarFrame: NSRect {
        let width = state.effectiveSidebarWidth
        if state.sidebarVisible {
            return NSRect(x: 0, y: 0, width: width, height: bounds.height)
        }
        let inset = Metrics.floatingSidebarInset
        let x = state.sidebarRevealed ? inset : -(width + 30)
        return NSRect(x: x, y: inset, width: width, height: bounds.height - inset * 2)
    }

    override func layout() {
        super.layout()
        let inset = Metrics.frameInset
        themeFrame.frame = bounds
        let sidebar = sidebarFrame
        sidebarHost.frame = sidebar
        floatingBackground.frame = sidebar
        floatingBackground.isHidden = state.sidebarVisible
        let cardX = state.sidebarVisible ? state.effectiveSidebarWidth : inset
        card.frame = NSRect(x: cardX, y: inset, width: max(0, bounds.width - cardX - inset),
                            height: max(0, bounds.height - inset * 2))
        themeFrame.cutout = themeFrame.convert(card.frame, from: self)
        toastHost.frame = card.frame
        cardOverlay?.frame = card.frame
        let findSize = FindBar.size
        findHost.frame = NSRect(x: card.frame.maxX - findSize.width - 12, y: card.frame.minY + card.toolbarHeight + 12,
                                width: findSize.width, height: findSize.height)
        if !switcherHost.isHidden { layoutSwitcher() }
        resizeHandle.frame = NSRect(x: sidebar.maxX - 4, y: sidebar.minY + inset, width: 8,
                                    height: sidebar.height - inset * 2)
        resizeHandle.isHidden = !(state.sidebarVisible || state.sidebarRevealed) || state.isLibraryOpen
        edgeTrigger.frame = NSRect(x: 0, y: 0, width: Metrics.edgeTriggerWidth, height: bounds.height)
        edgeTrigger.isHidden = state.sidebarVisible || state.sidebarRevealed
        (window as? BrowserWindow)?.layoutTrafficLights()
    }

    /// Fades the find bar in with a small drop, or out.
    func setFindVisible(_ visible: Bool) {
        guard visible == findHost.isHidden else { return }
        findHost.wantsLayer = true
        if visible {
            findHost.alphaValue = 0
            findHost.isHidden = false
            findHost.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -6))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.22 : 0.15
            context.timingFunction = Motion.expoOut
            context.allowsImplicitAnimation = true
            findHost.animator().alphaValue = visible ? 1 : 0
            findHost.layer?.setAffineTransform(.identity)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { if !visible { self?.findHost.isHidden = true } }
        }
    }

    /// A view laid over the content card (Peek), under the sidebar and other overlays.
    private weak var cardOverlay: NSView?

    func showOverlay(_ view: NSView) {
        if view.superview !== self { addSubview(view, positioned: .above, relativeTo: card) }
        cardOverlay = view
        view.frame = card.frame
    }

    private func layoutSwitcher() {
        let size = switcherHost.fittingSize
        let width = min(size.width, bounds.width)
        switcherHost.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - size.height) / 2,
                                    width: width, height: size.height).integral
    }

    /// Pops the Tab Switcher in (a quick scale up from 96%) or fades it out.
    func setSwitcherVisible(_ visible: Bool) {
        if visible {
            switcherHost.isHidden = false
            switcherHost.layoutSubtreeIfNeeded()
            layoutSwitcher()
            switcherHost.wantsLayer = true
            switcherHost.alphaValue = 0
            let bounds = switcherHost.bounds
            switcherHost.layer?.setAffineTransform(CGAffineTransform(translationX: bounds.width * 0.02, y: bounds.height * 0.02).scaledBy(x: 0.96, y: 0.96))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = Motion.expoOut
                context.allowsImplicitAnimation = true
                switcherHost.animator().alphaValue = 1
                switcherHost.layer?.setAffineTransform(.identity)
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                switcherHost.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { if self?.switcherHost.alphaValue == 0 { self?.switcherHost.isHidden = true } }
            }
        }
    }

    private func resizeSidebar(by delta: CGFloat) {
        state.sidebarWidth = min(Metrics.sidebarMaxWidth, max(Metrics.sidebarMinWidth, state.sidebarWidth + delta))
        needsLayout = true
    }
}

/// Rounded, themed backing for the floating sidebar (Arc: hide the sidebar, then point at the
/// left edge and it slides out over the page with a border and shadow).
final class FloatingSidebarBackground: NSView {
    private let theme = ThemeFrameView(cornerRadius: Metrics.floatingSidebarRadius, floating: true)
    var onExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        theme.wantsLayer = true
        theme.layer?.cornerRadius = Metrics.floatingSidebarRadius
        theme.layer?.cornerCurve = .continuous
        theme.layer?.masksToBounds = true
        theme.layer?.borderWidth = 1
        addSubview(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ palette: ThemePalette) {
        theme.apply(palette, animated: false)
        theme.layer?.borderColor = (palette.isDark ? NSColor.white.withAlphaComponent(0.14)
                                                   : NSColor.white.withAlphaComponent(0.55)).cgColor
    }

    override func layout() {
        super.layout()
        theme.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Metrics.floatingSidebarRadius,
                                   cornerHeight: Metrics.floatingSidebarRadius, transform: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // A little slack outside the panel so brushing past its edge doesn't dismiss it.
        // .assumeInside: the panel slides in under the pointer, so no "entered" event ever fires;
        // without it AppKit never sends the matching "exited" and the panel would stay out.
        addTrackingArea(NSTrackingArea(rect: bounds.insetBy(dx: -14, dy: -14),
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .assumeInside],
                                       owner: self, userInfo: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if !isHidden { onExit?() }
    }
}

/// Invisible strip along the window's left edge that reveals the hidden sidebar.
final class EdgeTriggerView: NSView {
    var onEnter: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        if !isHidden { onEnter?() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The sidebar reacts to the first click even when the window isn't active (clicking a tab in a
/// background window selects it immediately, like Arc).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
