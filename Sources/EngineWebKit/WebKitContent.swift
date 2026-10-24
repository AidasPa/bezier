import AppKit
import BezierEngine
import WebKit

@MainActor
final class WebKitContent: NSObject, WebContent {
    let id = UUID()
    let profile: ProfileID
    let state = WebContentState()
    weak var delegate: (any WebContentDelegate)?

    private let webView: WKWebView
    private unowned let engine: WebKitEngine
    private var observations: [NSKeyValueObservation] = []
    private var hasCommittedPage = false

    var view: NSView { webView }

    init(configuration: WKWebViewConfiguration, profile: ProfileID, engine: WebKitEngine) {
        self.profile = profile
        self.engine = engine
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.underPageBackgroundColor = .white
        engine.register(self, webView: webView)
        observe()
    }

    /// KVO only tells us *that* something changed; we then re-read everything on the main actor.
    private func observe() {
        func watch<V>(_ keyPath: KeyPath<WKWebView, V>) {
            observations.append(webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncState() }
            })
        }
        watch(\.url)
        watch(\.title)
        watch(\.isLoading)
        watch(\.estimatedProgress)
        watch(\.canGoBack)
        watch(\.canGoForward)
        watch(\.themeColor)
        syncState()
    }

    private func syncState() {
        state.url = webView.url
        state.title = (webView.title?.isEmpty ?? true) ? nil : webView.title
        state.isLoading = webView.isLoading
        state.progress = webView.estimatedProgress
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        state.themeColor = webView.themeColor
        delegate?.webContentDidChangeState(self)
    }

    func load(_ url: URL) {
        if url.isFileURL {
            _ = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            _ = webView.load(URLRequest(url: url))
        }
    }

    func goBack() { _ = webView.goBack() }
    func goForward() { _ = webView.goForward() }
    func reload(ignoringCache: Bool) { _ = ignoringCache ? webView.reloadFromOrigin() : webView.reload() }
    func stopLoading() { webView.stopLoading() }

    var pageZoom: Double {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    var magnification: Double { webView.magnification }

    func setMagnification(_ magnification: Double, centeredAt point: CGPoint) {
        webView.setMagnification(magnification, centeredAt: point)
    }

    func perform(_ command: MediaCommand) {
        let (name, value): (String, Any) = switch command {
        case .play: ("play", 0)
        case .pause: ("pause", 0)
        case .togglePlayback: ("toggle", 0)
        case .setMuted(let muted): ("mute", muted)
        case .skip(let seconds): ("skip", seconds)
        case .pictureInPicture: ("pip", 0)
        }
        webView.callAsyncJavaScript("window.__bezierMedia && window.__bezierMedia.command(name, value)",
                                    arguments: ["name": name, "value": value], in: nil, in: WebKitAutofill.world, completionHandler: nil)
    }

    func updateMedia(_ media: MediaState?) {
        guard media != state.media else { return }
        state.media = media
        delegate?.webContentDidChangeState(self)
    }

    func setVisible(_ visible: Bool) {
        // WebKit throttles hidden views on its own once they leave the window.
    }

    // MARK: Engine commands

    /// Web Inspector via WebKit SPI (`_inspector`). Fine for the development engine; the
    /// Chromium engine uses real DevTools.
    private var inspector: NSObject? {
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter) else { return nil }
        return webView.perform(getter)?.takeUnretainedValue() as? NSObject
    }

    private func inspectorCall(_ name: String) {
        let selector = NSSelectorFromString(name)
        guard let inspector, inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    func supports(_ command: EngineCommand) -> Bool {
        switch command {
        case .showDevTools, .showConsole, .inspectElement, .showNetwork: inspector != nil
        case .clearCookiesAndReload, .clearCacheAndReload: webView.url?.host() != nil
        }
    }

    func perform(_ command: EngineCommand) {
        switch command {
        case .showDevTools: inspectorCall("show")
        case .showConsole: inspectorCall("showConsole")
        case .showNetwork: inspectorCall("showResources")
        case .inspectElement:
            inspectorCall("show")
            inspectorCall("toggleElementSelection")
        case .clearCookiesAndReload:
            clearSiteData([WKWebsiteDataTypeCookies], thenReloadIgnoringCache: false)
        case .clearCacheAndReload:
            clearSiteData([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], thenReloadIgnoringCache: true)
        }
    }

    func snapshot() async -> NSImage? {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        return try? await webView.takeSnapshot(configuration: config)
    }

    func find(_ text: String, backwards: Bool, restart: Bool) async -> FindResult {
        guard !text.isEmpty else { return FindResult(found: false, matches: 0) }
        if restart { _ = try? await webView.callAsyncJavaScript("getSelection().removeAllRanges()", contentWorld: .defaultClient) }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let found = (try? await webView.find(text, configuration: configuration))?.matchFound ?? false
        let count = try? await webView.callAsyncJavaScript("""
            const haystack = (document.body ? document.body.innerText : '').toLocaleLowerCase();
            const needle = query.toLocaleLowerCase();
            let n = 0;
            for (let i = haystack.indexOf(needle); i !== -1 && n < 9999; i = haystack.indexOf(needle, i + needle.length)) n++;
            return n;
            """, arguments: ["query": text], contentWorld: .defaultClient)
        return FindResult(found: found, matches: (count as? Int) ?? (found ? 1 : 0))
    }

    func beginZap(_ picked: @escaping @MainActor (String?) -> Void) {
        engine.boosts.beginZap(in: webView, picked: picked)
    }

    func endZap() {
        engine.boosts.endZap(in: webView)
    }

    func snapshot(of rect: CGRect) async -> NSImage? {
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.afterScreenUpdates = true
        return try? await webView.takeSnapshot(configuration: config)
    }

    /// WebKit lays the whole page out as PDF (rect nil = everything); each page is drawn into
    /// one tall image at screen scale, capped so huge pages don't exhaust memory.
    func fullPageSnapshot() async -> NSImage? {
        guard let data = try? await webView.pdf(configuration: WKPDFConfiguration()),
              let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), pdf.numberOfPages > 0 else { return nil }
        let pages = (1...pdf.numberOfPages).compactMap { pdf.page(at: $0) }
        let boxes = pages.map { $0.getBoxRect(.mediaBox) }
        let width = boxes.map(\.width).max() ?? 0
        let height = boxes.reduce(0) { $0 + $1.height }
        guard width > 0, height > 0 else { return nil }
        let scale = min(webView.window?.backingScaleFactor ?? 2, 16_000 / height)
        let pixelsWide = Int(width * scale), pixelsHigh = Int(height * scale)
        guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.scaleBy(x: scale, y: scale)
        var top = height
        for (page, box) in zip(pages, boxes) {
            top -= box.height
            context.saveGState()
            context.translateBy(x: -box.minX, y: top - box.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    func selectedText() async -> String? {
        try? await webView.callAsyncJavaScript("return getSelection().toString()", contentWorld: .defaultClient) as? String
    }

    private func clearSiteData(_ types: Set<String>, thenReloadIgnoringCache ignoringCache: Bool) {
        guard let host = webView.url?.host()?.replacing(/^www\./, with: "") else { return }
        let store = webView.configuration.websiteDataStore
        Task { @MainActor in
            let records = await store.dataRecords(ofTypes: types)
            let matching = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            await store.removeData(ofTypes: types, for: matching)
            reload(ignoringCache: ignoringCache)
        }
    }

    private func detectFavicon() {
        let script = """
        (() => {
          const picks = ['link[rel="icon"][sizes="32x32"]', 'link[rel="icon"][type="image/png"]',
                         'link[rel~="icon"]', 'link[rel="shortcut icon"]', 'link[rel="apple-touch-icon"]'];
          for (const s of picks) { const l = document.querySelector(s); if (l && l.href) return l.href; }
          return location.origin + '/favicon.ico';
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let href = result as? String, let url = URL(string: href) else { return }
                if self.state.faviconURL != url {
                    self.state.faviconURL = url
                    self.delegate?.webContentDidChangeState(self)
                }
            }
        }
    }
}

extension WebKitContent: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommittedPage = true
        detectFavicon()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        detectFavicon()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // ⌘-click opens in a background tab, like every browser.
        if navigationAction.modifierFlags.contains(.command), navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            let content = engine.makeContent(profile: profile)
            content.load(url)
            delegate?.webContent(self, didOpen: content, disposition: .backgroundTab)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
           let url = navigationAction.request.url, delegate?.webContent(self, shouldInterceptLinkTo: url) == true {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        engine.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        engine.downloads.track(download)
        if !hasCommittedPage { delegate?.webContentDidBecomeDownloadOnly(self) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
}

extension WebKitContent: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit requires the returned view to use the configuration it hands us.
        let content = WebKitContent(configuration: configuration, profile: profile, engine: engine)
        // WebKit starts loading only after we return the view; say where it's going meanwhile.
        content.state.url = navigationAction.request.url
        let isPopup = windowFeatures.width != nil || windowFeatures.height != nil
        delegate?.webContent(self, didOpen: content, disposition: isPopup ? .popup : .foregroundTab)
        return content.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.webContentDidRequestClose(self)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: webView.window ?? NSApp.keyWindow!) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? ""
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? ""
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
