import AppKit
import BezierCore
import SwiftUI

/// Runs onboarding in its own small, centred, rounded window, then turns into the browser: the
/// window grows to the browser's frame while the ribbons open out and fade, and cross-fades into
/// the real browser window (whose sidebar slides in).
@MainActor
final class OnboardingController {
    static let completedKey = "OnboardingCompleted"

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    static let size = NSSize(width: 900, height: 600)
    static let cornerRadius: CGFloat = 22

    private weak var browser: BrowserWindowController?
    private var window: OnboardingWindow?
    private let container = NSView()
    private let shader = OnboardingShaderView()
    private let model = OnboardingModel()
    private var host: OnboardingHostingView?
    private var finishing = false
    private var keyMonitor: Any?

    init(browser: BrowserWindowController) {
        self.browser = browser
    }

    func start() {
        guard let browser else { return }
        model.onFinish = { [weak self] in self?.finish() }
        model.onImport = { [weak self] in await self?.importArc() }
        model.onChooseLook = { [weak self] look in self?.apply(look) }
        model.onMakeDefault = { [weak browser] in Task { await browser?.app.settings.makeDefaultBrowser() } }
        // The marbling shifts for each step. (Weak: the model and the shader hold these closures.)
        let shader = self.shader, model = self.model
        model.onStepChange = { [weak model, weak shader] step in
            shader?.stage = Float(model?.steps.firstIndex(of: step) ?? 0)
        }
        // The bottom bar goes light-on-dark over dark marbling (with some hysteresis).
        model.onBarFrame = { [weak shader] in shader?.sampleRect = $0 }
        shader.onSampleLuminance = { [weak model] luminance in
            guard let model else { return }
            if model.barIsDark ? luminance > 0.6 : luminance < 0.45 { model.barIsDark.toggle() }
        }

        let screen = browser.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.midX - Self.size.width / 2, y: visible.midY - Self.size.height / 2,
                           width: Self.size.width, height: Self.size.height)
        let window = OnboardingWindow(contentRect: frame)
        self.window = window

        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.frame = NSRect(origin: .zero, size: frame.size)
        container.autoresizingMask = [.width, .height]

        shader.frame = container.bounds
        shader.autoresizingMask = [.width, .height]
        container.addSubview(shader)

        let host = OnboardingHostingView(rootView: OnboardingView(model: model))
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        self.host = host
        window.contentView = container

        // → / space continue, ← back (text fields aside).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, !self.finishing, windowNumber == self.window?.windowNumber else { return false }
                switch code {
                case 124, 49: self.model.next(); return true
                case 123: self.model.back(); return true
                default: return false
                }
            }
            return handled ? nil : event
        }

        // Arrive: fade up with a small rise.
        window.alphaValue = 0
        var start = frame
        start.origin.y -= 14
        window.setFrame(start, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            context.timingFunction = Motion.expoOut
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
    }

    // MARK: Steps

    private func importArc() async -> ArcImportSummary? {
        await browser?.app.importFromArc(options: ArcImportOptions())
    }

    private func apply(_ look: OnboardingModel.Look) {
        guard let browser else { return }
        var theme: SpaceTheme
        switch look {
        case .neutral: theme = .neutral
        case .colour: theme = .lavender
        case .dark:
            theme = .neutral
            theme.appearance = .dark
        }
        browser.setTheme(theme, for: browser.currentSpace, animated: false)
    }

    // MARK: Becoming the browser

    private func finish() {
        guard !finishing, let browser, let window, let browserWindow = browser.window else { return }
        finishing = true
        Self.isCompleted = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }

        // 1. Words and controls leave.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            host?.animator().alphaValue = 0
        }

        // 2. The ribbons open out and fade to white…
        let bloomStart = CACurrentMediaTime()
        let shader = self.shader
        Task { @MainActor in
            while true {
                let p = min(1, (CACurrentMediaTime() - bloomStart) / 0.85)
                shader.reveal = Float(p * p)
                if p >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }

        // 3. …while the window grows into the browser's frame and its corners settle to a
        //    window's radius.
        let target = browserWindow.frame
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = Self.cornerRadius
        radius.toValue = 12
        radius.duration = 0.75
        radius.timingFunction = Motion.expoOut
        container.layer?.cornerRadius = 12
        container.layer?.add(radius, forKey: "radius")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.75
            context.timingFunction = Motion.expoOut
            window.animator().setFrame(target, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { self.handOff(to: browser) }
        }
    }

    /// 4. The real browser fades in where the onboarding window now sits; the sidebar slides in.
    private func handOff(to browser: BrowserWindowController) {
        guard let browserWindow = browser.window, let window else { return }
        let root = browser.root!
        if !browserWindow.isVisible { browserWindow.alphaValue = 0 }
        browserWindow.makeKeyAndOrderFront(nil)
        window.order(.above, relativeTo: browserWindow.windowNumber)

        root.sidebarHost.alphaValue = 0
        root.sidebarHost.layer?.setAffineTransform(CGAffineTransform(translationX: -24, y: 0))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            browserWindow.animator().alphaValue = 1
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                self.shader.isPaused = true
                self.window?.orderOut(nil)
                self.window = nil
                browser.onboardingFinished()
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            context.timingFunction = Motion.expoOut
            context.allowsImplicitAnimation = true
            root.sidebarHost.animator().alphaValue = 1
            root.sidebarHost.layer?.setAffineTransform(.identity)
        }
        browserWindow.makeFirstResponder(browser.selectedContent?.view)
    }
}

/// Clicks act straight away, even when Bezier isn't the active app (onboarding opens on its own).
final class OnboardingHostingView: NSHostingView<OnboardingView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, rounded, movable by its background; can take keyboard focus.
final class OnboardingWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
