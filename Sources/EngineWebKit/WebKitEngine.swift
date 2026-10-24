import AppKit
import BezierEngine
import WebKit

/// Development engine on WKWebView. Exists so the UI can be built and tuned before the
/// Chromium engine lands; it implements the same `WebEngine` contract.
@MainActor
public final class WebKitEngine: WebEngine {
    public let name = "WebKit"
    private var dataStores: [ProfileID: WKWebsiteDataStore] = [:]
    private let viewSource = ViewSourceSchemeHandler()
    public var downloadDirectory: URL = .downloadsDirectory
    public weak var downloadObserver: (any DownloadObserver)?
    public weak var credentialProvider: (any CredentialProvider)?
    lazy var downloads = WebKitDownloads(engine: self)
    private lazy var autofill = WebKitAutofill(engine: self)
    lazy var boosts = WebKitBoosts(engine: self)
    private lazy var media = WebKitMedia(engine: self)
    public var siteCustomizations: [SiteCustomization] = [] {
        didSet { boosts.update(siteCustomizations, webViews: liveWebViews) }
    }
    /// Live contents by web view, for script messages (popups share their opener's scripts).
    private let contentsByView = NSMapTable<WKWebView, WebKitContent>.weakToWeakObjects()

    public init() {}

    public func clearWebsiteData(profile: ProfileID) async {
        await dataStore(for: profile).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    public func makeContent(profile: ProfileID) -> any WebContent {
        WebKitContent(configuration: configuration(for: profile), profile: profile, engine: self)
    }

    func register(_ content: WebKitContent, webView: WKWebView) {
        contentsByView.setObject(content, forKey: webView)
    }

    func content(for webView: WKWebView) -> WebKitContent? {
        contentsByView.object(forKey: webView)
    }

    private var liveWebViews: [WKWebView] {
        contentsByView.keyEnumerator().allObjects.compactMap { $0 as? WKWebView }
    }

    /// Scripts are fixed when a page loads, so changing them means swapping the whole set.
    func rebuildUserScripts(_ controller: WKUserContentController) {
        controller.removeAllUserScripts()
        autofill.addScript(to: controller)
        media.addScript(to: controller)
        WebKitJSONViewer.addScript(to: controller)
        boosts.addScripts(to: controller)
    }

    func configuration(for profile: ProfileID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: profile)
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        autofill.install(in: config.userContentController)
        media.install(in: config.userContentController)
        WebKitJSONViewer.addScript(to: config.userContentController)
        boosts.installHandler(in: config.userContentController)
        boosts.addScripts(to: config.userContentController)
        if !WKWebView.handlesURLScheme(ViewSourceSchemeHandler.scheme) {
            config.setURLSchemeHandler(viewSource, forURLScheme: ViewSourceSchemeHandler.scheme)
        }
        return config
    }

    private func dataStore(for profile: ProfileID) -> WKWebsiteDataStore {
        if profile == .default { return .default() }
        if let store = dataStores[profile] { return store }
        let store = WKWebsiteDataStore(forIdentifier: Self.uuid(for: profile))
        dataStores[profile] = store
        return store
    }

    /// WebKit identifies persistent data stores by UUID; derive a stable one per profile.
    private static func uuid(for profile: ProfileID) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in profile.rawValue.utf8.enumerated() { bytes[i % 16] &+= b &* UInt8(truncatingIfNeeded: i + 1) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
