import AppKit
import Observation

/// A web rendering engine. The app only talks to engines through this module so the
/// WebKit development engine can be replaced by Chromium without touching UI code.
@MainActor
public protocol WebEngine: AnyObject {
    var name: String { get }

    /// Creates a new, empty web content for the given profile. Nothing loads until `load(_:)`.
    func makeContent(profile: ProfileID) -> any WebContent

    /// Where downloads are saved (default ~/Downloads) and who hears about them.
    var downloadDirectory: URL { get set }
    var downloadObserver: (any DownloadObserver)? { get set }
    /// Saved logins for autofill and saving; nil turns password handling off.
    var credentialProvider: (any CredentialProvider)? { get set }
    /// Per-site styles and scripts (Boosts), applied to open pages straight away.
    var siteCustomizations: [SiteCustomization] { get set }

    /// Removes cookies, caches, storage and other website data for a profile.
    func clearWebsiteData(profile: ProfileID) async
}

/// Download lifecycle events. The engine picks a unique destination in `downloadDirectory`.
@MainActor
public protocol DownloadObserver: AnyObject {
    func downloadDidStart(id: UUID, sourceURL: URL?, filename: String, destination: URL, cancel: @escaping @MainActor () -> Void)
    func downloadDidProgress(id: UUID, received: Int64, total: Int64)
    func downloadDidFinish(id: UUID)
    func downloadDidFail(id: UUID, cancelled: Bool)
}

/// Password autofill. The engine finds login fields and submitted logins in pages; the app
/// owns the saved passwords and the suggestion and save UI.
@MainActor
public protocol CredentialProvider: AnyObject {
    /// A login field gained focus, was clicked, or (username fields) was typed in.
    func content(_ content: any WebContent, didFocus field: LoginField)
    /// Arrow, Return or Escape in the field while suggestions show (see `LoginField.showSuggestions`).
    func content(_ content: any WebContent, didPress key: LoginField.Key, in field: LoginField)
    /// The field lost focus or the page scrolled under it.
    func contentDidLeaveLoginField(_ content: any WebContent)
    /// A login form was sent (submit, a click on its button, or Return in the password field).
    func content(_ content: any WebContent, didSubmitUsername username: String, password: String, origin: URL)
}

/// A focused login field in some frame of a page.
@MainActor
public final class LoginField {
    public enum Kind: Sendable { case username, password }
    public enum Key: Sendable { case up, down, enter, escape }
    /// What the field's arrow/Return keys do: nothing special, move through suggestions, or
    /// (with one highlighted) also take Return.
    public enum Suggestions: Int, Sendable { case hidden = 0, visible = 1, highlighted = 2 }

    /// `scheme://host[:port]` of the frame holding the field.
    public let origin: URL
    public let kind: Kind
    /// What's typed in a username field so far.
    public let typed: String
    /// The field in the content view's coordinates; nil inside frames it can't be placed in.
    public let frame: CGRect?
    private let fillHandler: @MainActor (String, String) -> Void
    private let suggestionsHandler: @MainActor (Suggestions) -> Void

    public init(origin: URL, kind: Kind, typed: String, frame: CGRect?,
                fill: @escaping @MainActor (String, String) -> Void,
                suggestions: @escaping @MainActor (Suggestions) -> Void) {
        self.origin = origin
        self.kind = kind
        self.typed = typed
        self.frame = frame
        fillHandler = fill
        suggestionsHandler = suggestions
    }

    /// Fills the username and password fields of the form, if the frame is still on `origin`.
    public func fill(username: String, password: String) { fillHandler(username, password) }
    /// Tells the page which keys to hand over (it can't wait for an answer when a key is pressed).
    public func showSuggestions(_ state: Suggestions) { suggestionsHandler(state) }
}

/// CSS and JavaScript for one site and its subdomains.
public struct SiteCustomization: Sendable, Equatable {
    /// "example.com" also matches "www.example.com" and "docs.example.com".
    public var domain: String
    public var css: String
    public var js: String
    public init(domain: String, css: String, js: String) {
        self.domain = domain
        self.css = css
        self.js = js
    }
}

public struct ProfileID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let `default` = ProfileID("default")
}

public enum OpenDisposition: Sendable {
    case foregroundTab
    case backgroundTab
    case popup
}

@MainActor
public protocol WebContentDelegate: AnyObject {
    func webContentDidChangeState(_ content: any WebContent)
    /// The page opened a new window (target=_blank, window.open, ⌘-click). The engine has
    /// already created and started loading `newContent`; the delegate decides where it lives.
    func webContent(_ content: any WebContent, didOpen newContent: any WebContent, disposition: OpenDisposition)
    func webContentDidRequestClose(_ content: any WebContent)
    /// A fresh content whose first navigation turned into a download; it has nothing to show.
    func webContentDidBecomeDownloadOnly(_ content: any WebContent)
    /// A plain link click is about to take the page to `url`. Return true to handle it instead
    /// (the engine then cancels the navigation), e.g. to open it in Peek.
    func webContent(_ content: any WebContent, shouldInterceptLinkTo url: URL) -> Bool
}

public extension WebContentDelegate {
    func webContent(_ content: any WebContent, shouldInterceptLinkTo url: URL) -> Bool { false }
}

/// One page's worth of web content: a view plus its navigation state.
@MainActor
public protocol WebContent: AnyObject {
    var id: UUID { get }
    var profile: ProfileID { get }
    /// The view to embed in a content card. Stays alive while the tab is loaded so tab
    /// switches are just a re-parent, never a reload.
    var view: NSView { get }
    var state: WebContentState { get }
    var delegate: (any WebContentDelegate)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload(ignoringCache: Bool)
    func stopLoading()

    var pageZoom: Double { get set }
    /// Visual pinch-zoom (1 = none). Separate from `pageZoom`, which reflows the page.
    var magnification: Double { get }
    func setMagnification(_ magnification: Double, centeredAt point: CGPoint)
    func perform(_ command: MediaCommand)

    /// Called when the content becomes (in)visible so the engine can throttle background work.
    func setVisible(_ visible: Bool)

    func supports(_ command: EngineCommand) -> Bool
    func perform(_ command: EngineCommand)

    /// Image of the visible page at screen resolution (Capture, Portrait Mode).
    func snapshot() async -> NSImage?
    /// Part of the visible page; `rect` is in the content view's coordinates.
    func snapshot(of rect: CGRect) async -> NSImage?
    /// The whole page, top to bottom.
    func fullPageSnapshot() async -> NSImage?

    /// Find on page: selects and scrolls to the next (or previous) match of `text`, case
    /// insensitively and wrapping; `restart` searches from the top of the page.
    func find(_ text: String, backwards: Bool, restart: Bool) async -> FindResult
    /// The text selected in the page, if any (⌘E Use Selection for Find).
    func selectedText() async -> String?

    /// Zap: highlights the element under the pointer and reports a CSS selector for each one
    /// clicked, until `endZap()` (or Escape in the page, reported as nil).
    func beginZap(_ picked: @escaping @MainActor (String?) -> Void)
    func endZap()
}

public struct FindResult: Sendable, Equatable {
    public var found: Bool
    /// Matches in the page's visible text (approximate: frames aren't counted).
    public var matches: Int
    public init(found: Bool, matches: Int) {
        self.found = found
        self.matches = matches
    }
}

/// Engine-specific capabilities the Command Bar and menus expose (Arc: View › Developer, etc.).
public enum EngineCommand: Sendable {
    case showDevTools
    case showConsole
    case inspectElement
    case showNetwork
    case clearCookiesAndReload
    case clearCacheAndReload
}

public extension URL {
    /// `view-source:<url>`; engines that support `supportsViewSource` render it as source.
    var viewSourceURL: URL? { URL(string: "view-source:" + absoluteString) }
}

/// Observable navigation state of a `WebContent`, published by the engine.
@MainActor
@Observable
public final class WebContentState {
    public var url: URL?
    public var title: String?
    public var faviconURL: URL?
    public var isLoading = false
    public var progress: Double = 0
    public var canGoBack = false
    public var canGoForward = false
    /// The page's `<meta name="theme-color">`, used to tint split-pane toolbars.
    public var themeColor: NSColor?
    /// The page's main audio or video, if it has started any.
    public var media: MediaState?

    public init() {}
}

/// What a page's media is doing (for the sidebar's speaker icon and the Mini Player).
public struct MediaState: Sendable, Equatable {
    public var isPlaying: Bool
    public var isMuted: Bool
    public var hasVideo: Bool
    public var title: String
    public var artist: String
    public var artworkURL: URL?

    public init(isPlaying: Bool, isMuted: Bool, hasVideo: Bool, title: String, artist: String, artworkURL: URL?) {
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.hasVideo = hasVideo
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
    }
}

public enum MediaCommand: Sendable, Equatable {
    case play, pause, togglePlayback
    case setMuted(Bool)
    /// Seconds forward (negative: back).
    case skip(Double)
    case pictureInPicture
}
