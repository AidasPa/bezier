import AppKit
import BezierCore
import Observation

/// User preferences, backed by UserDefaults. Auto-archive lives on `BrowserModel` because it
/// syncs with the sidebar document.
@MainActor
@Observable
final class BrowserSettings {
    var searchEngine: SearchEngine {
        didSet { defaults.set(searchEngine.rawValue, forKey: Keys.searchEngine) }
    }
    /// Live search-engine suggestions in the Command Bar (sends keystrokes to the engine).
    var showSearchSuggestions: Bool {
        didSet { defaults.set(showSearchSuggestions, forKey: Keys.suggestions) }
    }
    /// URL pill shows the full address instead of just the domain.
    var showFullURL: Bool {
        didSet { defaults.set(showFullURL, forKey: Keys.fullURL) }
    }
    /// Time-zone answers ("4pm utc") in the Command Bar.
    var showTimeConversions: Bool {
        didSet { defaults.set(showTimeConversions, forKey: Keys.timeZones) }
    }
    var downloadDirectory: URL {
        didSet { defaults.set(downloadDirectory.path(percentEncoded: false), forKey: Keys.downloads) }
    }
    enum WebsiteAppearance: String, CaseIterable, Identifiable {
        case automatic, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// What web views get: nil follows the system.
        var nsAppearance: NSAppearance? {
            switch self {
            case .automatic: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// Light/dark for page content (`prefers-color-scheme`), independent of the Space theme.
    var websiteAppearance: WebsiteAppearance {
        didSet {
            defaults.set(websiteAppearance.rawValue, forKey: Keys.websiteAppearance)
            onWebsiteAppearanceChange?()
        }
    }
    @ObservationIgnored var onWebsiteAppearanceChange: (() -> Void)?

    /// Air Traffic Control: sites whose links (from other apps) open in a given Space.
    var linkRoutes: [LinkRoute] {
        didSet { if let data = try? JSONEncoder().encode(linkRoutes) { defaults.set(data, forKey: Keys.linkRoutes) } }
    }

    /// Links from pinned tabs and Favorites to other sites open in Peek.
    var openLinksInPeek: Bool {
        didSet { defaults.set(openLinksInPeek, forKey: Keys.peek) }
    }

    /// Fill saved passwords into login forms.
    var autofillPasswords: Bool {
        didSet { defaults.set(autofillPasswords, forKey: Keys.autofillPasswords) }
    }
    /// Ask to save (or update) passwords typed into login forms.
    var offerToSavePasswords: Bool {
        didSet { defaults.set(offerToSavePasswords, forKey: Keys.offerToSavePasswords) }
    }

    /// Per-site Developer Mode choices that differ from the default (on for local servers).
    var developerModeOverrides: [String: Bool] {
        didSet { defaults.set(developerModeOverrides, forKey: Keys.devMode) }
    }

    func isDeveloperMode(_ url: URL?) -> Bool {
        DeveloperMode.isEnabled(for: url, overrides: developerModeOverrides)
    }

    /// ⌃D. Stores only deviations from the default so localhost stays on unless turned off.
    func toggleDeveloperMode(for url: URL?) {
        guard let key = DeveloperMode.siteKey(url) else { return }
        let enabled = !isDeveloperMode(url)
        developerModeOverrides[key] = enabled == DeveloperMode.isLocal(url) ? nil : enabled
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let searchEngine = "SearchEngine"
        static let suggestions = "ShowSearchSuggestions"
        static let fullURL = "ShowFullURL"
        static let timeZones = "ShowTimeConversions"
        static let downloads = "DownloadDirectory"
        static let devMode = "DeveloperModeOverrides"
        static let websiteAppearance = "WebsiteAppearance"
        static let peek = "OpenLinksInPeek"
        static let linkRoutes = "LinkRoutes"
        static let autofillPasswords = "AutofillPasswords"
        static let offerToSavePasswords = "OfferToSavePasswords"
    }

    init() {
        defaults.register(defaults: [Keys.suggestions: true, Keys.fullURL: false, Keys.timeZones: true,
                                     Keys.autofillPasswords: true, Keys.offerToSavePasswords: true, Keys.peek: true])
        searchEngine = defaults.string(forKey: Keys.searchEngine).flatMap(SearchEngine.init(rawValue:)) ?? .google
        showSearchSuggestions = defaults.bool(forKey: Keys.suggestions)
        showFullURL = defaults.bool(forKey: Keys.fullURL)
        showTimeConversions = defaults.bool(forKey: Keys.timeZones)
        downloadDirectory = defaults.string(forKey: Keys.downloads).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? .downloadsDirectory
        developerModeOverrides = defaults.dictionary(forKey: Keys.devMode) as? [String: Bool] ?? [:]
        websiteAppearance = defaults.string(forKey: Keys.websiteAppearance).flatMap(WebsiteAppearance.init(rawValue:)) ?? .automatic
        openLinksInPeek = defaults.bool(forKey: Keys.peek)
        linkRoutes = defaults.data(forKey: Keys.linkRoutes).flatMap { try? JSONDecoder().decode([LinkRoute].self, from: $0) } ?? []
        autofillPasswords = defaults.bool(forKey: Keys.autofillPasswords)
        offerToSavePasswords = defaults.bool(forKey: Keys.offerToSavePasswords)
    }

    // MARK: Default browser

    var isDefaultBrowser: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    /// macOS shows its own confirmation dialog.
    func makeDefaultBrowser() async {
        for scheme in ["http", "https"] {
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
        }
    }
}
