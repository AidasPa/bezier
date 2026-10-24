import AppKit

/// Borderless-looking window: full-size content, transparent titlebar, traffic lights
/// moved into the sidebar's top row (Arc has no titlebar).
final class BrowserWindow: NSWindow {
    /// Hidden with the sidebar, like Arc.
    var trafficLightsVisible = true {
        didSet { layoutTrafficLights() }
    }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        collectionBehavior.insert(.fullScreenPrimary)
        minSize = NSSize(width: 520, height: 380)
        backgroundColor = .clear
        isOpaque = false
        acceptsMouseMovedEvents = true
    }

    /// Vertical centre of the traffic lights from the window's top edge.
    var trafficLightCenterY: CGFloat = Metrics.frameInset + Metrics.toolbarHeight / 2

    func layoutTrafficLights() {
        guard let close = standardWindowButton(.closeButton), let titlebar = close.superview,
              let container = titlebar.superview else { return }
        if styleMask.contains(.fullScreen) { return }
        let height = trafficLightCenterY * 2 - 10
        let target = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
        if container.frame != target { container.frame = target }
        let centerFromTop = trafficLightCenterY
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, kind) in kinds.enumerated() {
            guard let button = standardWindowButton(kind) else { continue }
            let cx = Metrics.trafficLightFirstCenterX + CGFloat(i) * Metrics.trafficLightSpacing
            let origin = NSPoint(x: (cx - button.frame.width / 2).rounded(),
                                 y: (titlebar.frame.height - centerFromTop - button.frame.height / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            button.isHidden = !trafficLightsVisible
        }
    }

    /// Browser shortcuts win over web pages (Arc behaviour: ⌘S toggles the sidebar even on
    /// sites that bind ⌘S). Edit commands still reach the page through the responder chain.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 48, event.modifierFlags.contains(.control), let browser = windowController as? BrowserWindowController {
            browser.advanceTabSwitcher(backwards: event.modifierFlags.contains(.shift))      // ⌃Tab
            return true
        }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// The Tab Switcher commits when Control is let go and cancels on Escape.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let browser = windowController as? BrowserWindowController,
           browser.root.sidebarFrame.contains(browser.root.convert(event.window == nil ? convertPoint(fromScreen: event.locationInWindow)
                                                                                     : event.locationInWindow, from: nil)),
           browser.state.sidebarVisible || browser.state.sidebarRevealed, !browser.state.isLibraryOpen,
           browser.handleSidebarScroll(event) {
            return
        }
        if let browser = windowController as? BrowserWindowController, browser.isTabSwitcherActive {
            if event.type == .flagsChanged, !event.modifierFlags.contains(.control) {
                browser.commitTabSwitcher()
            } else if event.type == .keyDown, event.keyCode == 53 {
                browser.endTabSwitcher()
                return
            } else if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.contains(.control) {
                browser.advanceTabSwitcher(backwards: event.modifierFlags.contains(.shift))
                return
            }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        (windowController as? BrowserWindowController)?.endTabSwitcher()
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }
}
