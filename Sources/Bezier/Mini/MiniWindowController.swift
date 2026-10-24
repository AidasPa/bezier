import AppKit
import BezierCore
import BezierEngine
import SwiftUI

/// Mini Bezier (Arc's Little Arc): a small, rounded glass window for links from other apps,
/// sign-in popups and quick lookups (⌥⌘N). "Open in <Space>" (⌘O) moves the live page into the
/// main window without reloading it.
@MainActor
final class MiniWindowController: NSWindowController, NSWindowDelegate, WebContentDelegate, NSMenuItemValidation {
    let app: AppContext
    private(set) var content: (any WebContent)?
    let initialURL: URL?
    let state: MiniState
    private var root: MiniRootView!

    static let topBarHeight: CGFloat = 44
    private static let sizeKey = "MiniWindowSize"

    init(app: AppContext, content: any WebContent, initialURL: URL?, editing: Bool = false) {
        self.app = app
        self.content = content
        self.initialURL = initialURL
        let space = app.activeWindow?.currentSpace ?? app.model.spaces[0]
        state = MiniState(space: space, systemIsDark: NSApp.effectiveAppearance.isDark)
        state.isEditingURL = editing
        let saved = NSSizeFromString(UserDefaults.standard.string(forKey: Self.sizeKey) ?? "")
        let size = saved.width > 300 ? saved : NSSize(width: 880, height: 660)
        let window = BrowserWindow(contentRect: NSRect(origin: .zero, size: size))
        window.trafficLightCenterY = Self.topBarHeight / 2
        window.minSize = NSSize(width: 420, height: 320)
        super.init(window: window)
        window.delegate = self
        content.delegate = self
        content.view.appearance = app.settings.websiteAppearance.nsAppearance

        root = MiniRootView(topBar: MiniTopBar(controller: self, state: state))
        window.contentView = root
        root.card.show(content.view)
        root.card.setKey(true)
        applyTheme()
        position(window)
        window.title = initialURL.map(URLInput.displayHost) ?? "Mini Bezier"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Centred on the screen under the pointer; cascades if another mini is already there.
    private func position(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return window.center() }
        var frame = window.frame
        frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2 + 30)
        let offset = CGFloat(app.miniWindows.count) * 24
        frame.origin.x += offset
        frame.origin.y -= offset
        window.setFrame(frame, display: false)
    }

    func applyTheme() {
        let palette = ThemePalette(theme: state.space.theme, systemIsDark: NSApp.effectiveAppearance.isDark)
        state.palette = palette
        root.themeFrame.apply(palette, animated: false)
        root.card.apply(palette)
    }

    var currentURL: URL? { content?.state.url ?? initialURL }

    // MARK: Actions

    func load(_ text: String) {
        let url = URLInput.directURL(text) ?? app.settings.searchEngine.searchURL(for: text)
        content?.load(url)
        state.isEditingURL = false
    }

    /// ⌘O. Hands the live page to the main window as a Today tab in the Space shown on the button.
    @objc func openInSpace(_ sender: Any?) {
        guard let content else { return }
        let browser = app.activeWindow ?? app.windows.first ?? app.openWindow()
        let space = app.model.space(state.space.id) ?? browser.currentSpace
        let tab = withAnimation(Motion.spring) {
            app.model.newTab(url: content.state.url ?? initialURL, in: space, title: content.state.title)
        }
        content.view.removeFromSuperview()
        app.contents.adopt(content, for: tab)
        self.content = nil
        close()
        browser.switchToSpace(space, selecting: tab)
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func archiveTab(_ sender: Any?) { close() }
    @objc func openLocation(_ sender: Any?) { state.isEditingURL = true }
    @objc func reloadPage(_ sender: Any?) { content?.reload(ignoringCache: false) }
    @objc func forceReloadPage(_ sender: Any?) { content?.reload(ignoringCache: true) }
    @objc func goBack(_ sender: Any?) { content?.goBack() }
    @objc func goForward(_ sender: Any?) { content?.goForward() }
    @objc func stopLoading(_ sender: Any?) { content?.stopLoading() }

    @objc func copyURL(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        state.toasts.show("Copied URL", symbol: "link")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): content?.state.canGoBack ?? false
        case #selector(goForward(_:)): content?.state.canGoForward ?? false
        case #selector(openInSpace(_:)):
            { item.title = "Open in \(state.space.title)"; return content != nil }()
        default: true
        }
    }

    // MARK: WebContentDelegate

    func webContentDidChangeState(_ content: any WebContent) {
        window?.title = content.state.title ?? URLInput.displayHost(content.state.url)
        if let url = content.state.url { app.history.recordVisit(url, title: content.state.title, faviconURL: content.state.faviconURL) }
    }

    func webContent(_ content: any WebContent, didOpen newContent: any WebContent, disposition: OpenDisposition) {
        app.openMini(content: newContent)
    }

    func webContentDidRequestClose(_ content: any WebContent) { close() }
    func webContentDidBecomeDownloadOnly(_ content: any WebContent) { close() }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) { (window as? BrowserWindow)?.layoutTrafficLights() }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let size = window?.frame.size { UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey) }
    }

    func windowWillClose(_ notification: Notification) {
        content?.stopLoading()
        content?.view.removeFromSuperview()
        content?.delegate = nil
        content = nil
        app.miniClosed(self)
    }
}

@MainActor
@Observable
final class MiniState {
    var space: Space
    var palette: ThemePalette
    var isEditingURL = false
    let toasts = ToastCenter()

    init(space: Space, systemIsDark: Bool) {
        self.space = space
        palette = ThemePalette(theme: space.theme, systemIsDark: systemIsDark)
    }
}

/// Glass frame, top bar, and the rounded page card inset in a thin rim.
final class MiniRootView: NSView {
    let themeFrame = ThemeFrameView()
    let card = ContentCardView()
    private let topBar: NSView
    private let toastHost: NSView
    static let rim: CGFloat = 6

    init(topBar: MiniTopBar) {
        let host = NSHostingView(rootView: topBar)
        host.safeAreaRegions = []
        host.sizingOptions = []
        self.topBar = host
        let toast = PassthroughHostingView(rootView: ToastOverlay(center: topBar.state.toasts))
        toast.safeAreaRegions = []
        toast.sizingOptions = []
        toastHost = toast
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(themeFrame)
        addSubview(card)
        addSubview(host)
        addSubview(toast)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let bar = MiniWindowController.topBarHeight
        let rim = Self.rim
        themeFrame.frame = bounds
        topBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bar)
        card.frame = NSRect(x: rim, y: bar, width: bounds.width - rim * 2, height: bounds.height - bar - rim)
        toastHost.frame = card.frame
        (window as? BrowserWindow)?.layoutTrafficLights()
    }
}

/// Traffic lights · domain pill (click to edit, ⌘L) · copy link · "Open in <Space> ⌘O".
struct MiniTopBar: View {
    let controller: MiniWindowController
    let state: MiniState

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let palette = state.palette
        let contentState = controller.content?.state
        HStack(spacing: 8) {
            Color.clear.frame(width: 64)
            Spacer(minLength: 8)
            Group {
                if state.isEditingURL {
                    TextField("Search or Enter URL…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .onAppear { draft = controller.currentURL?.absoluteString ?? ""; focused = true }
                        .onSubmit { if !draft.isEmpty { controller.load(draft) } }
                        .onExitCommand { state.isEditingURL = false }
                } else {
                    HStack(spacing: 6) {
                        if contentState?.url?.scheme == "https" {
                            Image(systemName: "lock.fill").font(.system(size: 9.5)).foregroundStyle(palette.icon)
                        }
                        Text(URLInput.displayHost(controller.currentURL))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.ink.opacity(0.85))
                            .lineLimit(1)
                    }
                    .onTapGesture { state.isEditingURL = true }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: 440)
            .frame(height: 28)
            .background(Capsule().fill(palette.well))
            .overlay(alignment: .bottom) {
                if contentState?.isLoading == true {
                    Capsule().fill(palette.accent.opacity(0.8))
                        .frame(height: 2)
                        .scaleEffect(x: max(0.05, contentState?.progress ?? 0), anchor: .leading)
                        .padding(.horizontal, 10)
                        .animation(.easeOut(duration: 0.25), value: contentState?.progress)
                }
            }
            Spacer(minLength: 8)
            IconButton(symbol: "link", palette: palette, size: 12.5, help: "Copy URL (⇧⌘C)") { controller.copyURL(nil) }
            Button { controller.openInSpace(nil) } label: {
                HStack(spacing: 6) {
                    Text("Open in \(state.space.icon.map { "\($0) " } ?? "")\(state.space.title)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("⌘O").font(.system(size: 10.5, weight: .medium, design: .rounded)).opacity(0.55)
                }
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color.white))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            }
            .buttonStyle(PressableStyle(scale: 0.94))
            .help("Move this page into your \(state.space.title) Space")
        }
        .padding(.trailing, 8)
        .frame(height: MiniWindowController.topBarHeight)
        .background(WindowDragArea())
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }
}
