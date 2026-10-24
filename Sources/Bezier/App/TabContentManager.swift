import AppKit
import BezierCore
import BezierEngine

/// Owns the live `WebContent` behind each loaded tab and keeps the model in sync with it.
/// Tabs without content are "unloaded" (pinned tabs after ⌘W, restored sessions) and
/// cost nothing until selected.
@MainActor
final class TabContentManager: WebContentDelegate {
    private let engine: any WebEngine
    private let model: BrowserModel
    private let history: HistoryStore
    private var contents: [UUID: any WebContent] = [:]
    private var tabIDsByContent: [UUID: UUID] = [:]
    /// Last URL written to history per content, so title updates don't count as visits.
    private var lastRecorded: [UUID: URL] = [:]

    /// Where to put tabs a page opens. Set by the key window controller.
    var openHandler: ((_ opener: BrowserTab, _ newTab: BrowserTab, _ disposition: OpenDisposition) -> Void)?
    var closeHandler: ((BrowserTab) -> Void)?
    /// Removes a tab without archiving it (e.g. it only existed to start a download).
    var discardHandler: ((BrowserTab) -> Void)?
    /// A sized popup (window.open with dimensions); shown in a mini window.
    var popupHandler: ((any WebContent) -> Void)?
    /// Links from pinned tabs and Favorites to other sites open in Peek (when this is set).
    var peekHandler: ((_ opener: BrowserTab, _ content: any WebContent) -> Void)?
    var peekEnabled: () -> Bool = { true }
    var media: MediaCenter?

    /// Takes over a live content from a mini window ("Open in Space") without reloading it.
    func adopt(_ content: any WebContent, for tab: BrowserTab) {
        register(content, for: tab)
    }
    /// A tab's URL changed (windows re-evaluate Developer Mode).
    var urlChangeHandler: ((BrowserTab) -> Void)?

    init(engine: any WebEngine, model: BrowserModel, history: HistoryStore) {
        self.engine = engine
        self.model = model
        self.history = history
    }

    func existingContent(for tab: BrowserTab) -> (any WebContent)? { contents[tab.id] }

    /// Small pictures of pages as they last looked on screen (Tab Switcher cards).
    private(set) var thumbnails: [UUID: NSImage] = [:]

    /// Snapshots the tab's page; only works while it's on screen.
    func captureThumbnail(for tab: BrowserTab) {
        guard let content = contents[tab.id], content.view.window != nil else { return }
        Task { @MainActor in
            guard let image = await content.snapshot() else { return }
            thumbnails[tab.id] = image.downscaled(toWidth: 360)
        }
    }

    func isLoaded(_ tab: BrowserTab) -> Bool { contents[tab.id] != nil }

    /// Returns the tab's content, creating and loading it on first use.
    func content(for tab: BrowserTab, profile: ProfileID) -> any WebContent {
        if let content = contents[tab.id] { return content }
        let content = engine.makeContent(profile: profile)
        register(content, for: tab)
        if let url = tab.url ?? tab.pinnedURL { content.load(url) }
        return content
    }

    /// Drops the tab's web content (⌘W on a pinned tab or favorite, or archiving).
    func unload(_ tab: BrowserTab) {
        guard let content = contents.removeValue(forKey: tab.id) else { return }
        tabIDsByContent[content.id] = nil
        thumbnails[tab.id] = nil
        media?.remove(tab.id)
        content.stopLoading()
        content.view.removeFromSuperview()
        content.delegate = nil
    }

    var loadedTabIDs: Set<UUID> { Set(contents.keys) }

    /// Website light/dark override applied to every page view.
    var contentAppearance: NSAppearance? {
        didSet { for content in contents.values { content.view.appearance = contentAppearance } }
    }

    private func register(_ content: any WebContent, for tab: BrowserTab) {
        content.delegate = self
        content.view.appearance = contentAppearance
        contents[tab.id] = content
        tabIDsByContent[content.id] = tab.id
    }

    private func tab(for content: any WebContent) -> BrowserTab? {
        tabIDsByContent[content.id].flatMap(model.tab(id:))
    }

    // MARK: WebContentDelegate

    func webContentDidChangeState(_ content: any WebContent) {
        guard let tab = tab(for: content) else { return }
        let state = content.state
        if media?.states[tab.id] != state.media { media?.update(tab.id, state.media) }
        var changed = false
        if let url = state.url, url != tab.url || lastRecorded[content.id] != url {
            if url != tab.url { tab.url = url; changed = true; urlChangeHandler?(tab) }
            lastRecorded[content.id] = url
            history.recordVisit(url, title: state.title, faviconURL: state.faviconURL)
        } else if let url = state.url {
            history.update(url, title: state.title, faviconURL: state.faviconURL)
        }
        if let title = state.title, title != tab.title { tab.title = title; changed = true }
        if let favicon = state.faviconURL, favicon != tab.faviconURL { tab.faviconURL = favicon; changed = true }
        if changed { model.didChange() }
    }

    func webContent(_ content: any WebContent, didOpen newContent: any WebContent, disposition: OpenDisposition) {
        guard let opener = tab(for: content) else { return }
        let space: Space? = switch model.location(of: opener) {
        case .today(let id)?, .pinned(let id)?: model.space(id)
        default: nil
        }
        guard let space = space ?? model.spaces.first else { return }
        if disposition == .popup {
            // Sign-in and other sized popups keep window.opener working inside a mini window.
            popupHandler?(newContent)
            return
        }
        if disposition == .foregroundTab, opensInPeek(from: opener, to: newContent.state.url), let peekHandler {
            peekHandler(opener, newContent)
            return
        }
        let newTab = model.openChild(url: newContent.state.url, from: opener, in: space)
        register(newContent, for: newTab)
        openHandler?(opener, newTab, disposition)
    }

    func webContent(_ content: any WebContent, shouldInterceptLinkTo url: URL) -> Bool {
        guard let opener = tab(for: content), opensInPeek(from: opener, to: url), let peekHandler else { return false }
        let peek = engine.makeContent(profile: content.profile)
        peek.view.appearance = contentAppearance
        peek.load(url)
        peekHandler(opener, peek)
        return true
    }

    /// Arc's Peek: pinned tabs and Favorites stay put; links that leave their site preview on top.
    private func opensInPeek(from opener: BrowserTab, to url: URL?) -> Bool {
        guard peekEnabled(), let url, let home = opener.pinnedURL ?? opener.url else { return false }
        switch model.location(of: opener) {
        case .pinned?, .favorite?: return !Self.sameSite(home, url)
        default: return false
        }
    }

    /// Same registrable-ish domain: hosts equal, or one is a subdomain of the other.
    static func sameSite(_ a: URL, _ b: URL) -> Bool {
        func host(_ url: URL) -> String { (url.host() ?? "").lowercased().replacing(/^www\./, with: "") }
        let x = host(a), y = host(b)
        return x == y || x.hasSuffix("." + y) || y.hasSuffix("." + x)
    }

    func webContentDidBecomeDownloadOnly(_ content: any WebContent) {
        guard let tab = tab(for: content) else { return }
        discardHandler?(tab)
    }

    func webContentDidRequestClose(_ content: any WebContent) {
        guard let tab = tab(for: content) else { return }
        closeHandler?(tab)
    }
}
