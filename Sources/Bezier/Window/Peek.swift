import AppKit
import BezierCore
import BezierEngine
import SwiftUI

/// Arc's Peek: a link from a pinned tab or Favorite to another site opens in a card floating
/// over the page, so the pinned tab stays where it was. Open it as a tab, or click outside it
/// (or press Escape) to close it.
@MainActor
final class PeekController: WebContentDelegate {
    private unowned let browser: BrowserWindowController
    private let overlay = PeekOverlayView()
    private let model = PeekModel()
    private(set) var content: (any WebContent)?
    private var keyMonitor: Any?

    var isShowing: Bool { content != nil }

    init(browser: BrowserWindowController) {
        self.browser = browser
        overlay.onDismiss = { [weak self] in self?.close() }
        model.onOpenAsTab = { [weak self] in self?.openAsTab() }
        model.onClose = { [weak self] in self?.close() }
        overlay.toolbar = NSHostingView(rootView: PeekToolbar(model: model))
    }

    func show(_ content: any WebContent) {
        if let old = self.content { discard(old) }
        self.content = content
        content.delegate = self
        sync(content)
        overlay.setPage(content.view)
        overlay.apply(browser.state.palette)
        browser.root.showOverlay(overlay)
        overlay.animateIn()
        browser.window?.makeFirstResponder(content.view)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let isEscape = event.keyCode == 53 && event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
                let window = event.window
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, isEscape, self.isShowing, window === self.browser.window else { return false }
                    self.close()
                    return true
                }
                return handled ? nil : event
            }
        }
    }

    /// Keeps the live page (no reload) as a new tab in the current Space.
    func openAsTab() {
        guard let content else { return }
        let tab = withAnimation(Motion.spring) {
            browser.model.newTab(url: content.state.url, in: browser.currentSpace, title: content.state.title)
        }
        content.view.removeFromSuperview()
        browser.app.contents.adopt(content, for: tab)
        self.content = nil
        dismiss()
        browser.select(tab)
    }

    func close() {
        guard let content else { return }
        discard(content)
        self.content = nil
        dismiss()
        if let view = browser.selectedContent?.view { browser.window?.makeFirstResponder(view) }
    }

    private func discard(_ content: any WebContent) {
        content.stopLoading()
        content.delegate = nil
        content.view.removeFromSuperview()
    }

    private func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        overlay.animateOut { [weak self] in
            guard let self, self.content == nil else { return }
            self.overlay.removeFromSuperview()
        }
    }

    private func sync(_ content: any WebContent) {
        model.title = content.state.title ?? ""
        model.host = URLInput.displayHost(content.state.url)
        model.isLoading = content.state.isLoading
    }

    // MARK: WebContentDelegate

    func webContentDidChangeState(_ content: any WebContent) {
        sync(content)
        if let url = content.state.url {
            browser.app.history.recordVisit(url, title: content.state.title, faviconURL: content.state.faviconURL)
        }
    }

    /// Links that open new tabs from inside Peek become ordinary tabs.
    func webContent(_ content: any WebContent, didOpen newContent: any WebContent, disposition: OpenDisposition) {
        let tab = browser.model.newTab(url: newContent.state.url, in: browser.currentSpace, title: nil)
        browser.app.contents.adopt(newContent, for: tab)
        if disposition != .backgroundTab {
            close()
            browser.select(tab)
        }
    }

    func webContentDidRequestClose(_ content: any WebContent) { close() }
    func webContentDidBecomeDownloadOnly(_ content: any WebContent) { close() }
}

@MainActor
@Observable
final class PeekModel {
    var title = ""
    var host = ""
    var isLoading = false
    @ObservationIgnored var onOpenAsTab: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
}

private struct PeekToolbar: View {
    let model: PeekModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.onClose?() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.85))
            .help("Close (Esc)")
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title.isEmpty ? model.host : model.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !model.title.isEmpty { Text(model.host).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { model.onOpenAsTab?() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10.5, weight: .semibold))
                    Text("Open as Tab").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.94))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dimmed page with the Peek card on top. Clicking the dimmed part closes it.
final class PeekOverlayView: NSView {
    var onDismiss: (() -> Void)?
    var toolbar: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let toolbar { card.addSubview(toolbar) }
        }
    }
    private let backdrop = NSView()
    private let lift = NSView()
    private let card = NSView()
    private weak var page: NSView?
    private static let toolbarHeight: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Metrics.cardRadius
        backdrop.layer?.cornerCurve = .continuous
        addSubview(backdrop)
        lift.wantsLayer = true
        lift.layer?.shadowColor = NSColor.black.cgColor
        lift.layer?.shadowOpacity = 0.3
        lift.layer?.shadowRadius = 24
        lift.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(lift)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        lift.addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ palette: ThemePalette) {
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.4 : 0.22).cgColor
        card.layer?.backgroundColor = (palette.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.98, alpha: 1)).cgColor
        card.layer?.borderColor = palette.cardHairline.cgColor
    }

    func setPage(_ view: NSView) {
        page?.removeFromSuperview()
        view.removeFromSuperview()
        view.autoresizingMask = []
        card.addSubview(view)
        page = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        let width = (bounds.width * 0.86).rounded(), height = (bounds.height * 0.9).rounded()
        let frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        lift.frame = frame
        lift.layer?.shadowPath = CGPath(roundedRect: lift.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        card.frame = lift.bounds
        let bar = Self.toolbarHeight
        toolbar?.frame = NSRect(x: 0, y: card.bounds.height - bar, width: card.bounds.width, height: bar)
        page?.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: card.bounds.height - bar)
    }

    override func mouseDown(with event: NSEvent) {
        // Only the dimmed area reaches here; the card's subviews take their own clicks.
        if !lift.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }

    func animateIn() {
        layoutSubtreeIfNeeded()
        backdrop.alphaValue = 0
        lift.alphaValue = 0
        lift.layer?.setAffineTransform(CGAffineTransform(translationX: lift.bounds.width * 0.03, y: lift.bounds.height * 0.03 - 10)
            .scaledBy(x: 0.94, y: 0.94))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.1, 0.35, 1)    // a small overshoot
            context.allowsImplicitAnimation = true
            backdrop.animator().alphaValue = 1
            lift.animator().alphaValue = 1
            lift.layer?.setAffineTransform(.identity)
        }
    }

    func animateOut(completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            backdrop.animator().alphaValue = 0
            lift.animator().alphaValue = 0
            lift.layer?.setAffineTransform(CGAffineTransform(translationX: lift.bounds.width * 0.02, y: lift.bounds.height * 0.02)
                .scaledBy(x: 0.96, y: 0.96))
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }
}
