import AppKit
import BezierCore
import BezierEngine
import EngineWebKit

/// App-wide services shared by all windows.
@MainActor
final class AppContext {
    let engine: any WebEngine
    let store: BrowserStore
    let model: BrowserModel
    let contents: TabContentManager
    let settings = BrowserSettings()
    let history: HistoryStore
    let downloads: DownloadsCoordinator
    let suggestions = SearchSuggestions()
    let media = MediaCenter()
    let shortcuts = ShortcutStore()
    let passwords: PasswordManager
    let boosts: BoostsController
    private(set) var windows: [BrowserWindowController] = []
    private(set) var miniWindows: [MiniWindowController] = []
    weak var activeWindow: BrowserWindowController?
    private var autoArchiveTimer: Timer?

    init() {
        engine = WebKitEngine()
        store = BrowserStore()
        model = store.load()
        history = HistoryStore()
        downloads = DownloadsCoordinator(store: DownloadsStore())
        contents = TabContentManager(engine: engine, model: model, history: history)
        contents.media = media
        engine.downloadObserver = downloads
        #if DEBUG
        // Automation runs get a throwaway vault: an in-memory key and nothing written to disk.
        if ProcessInfo.processInfo.environment["BEZIER_TEST_VAULT"] == "1" {
            passwords = PasswordManager(settings: settings, vault: PasswordVault(directory: nil, keyStore: EphemeralVaultKeyStore()))
        } else {
            passwords = PasswordManager(settings: settings)
        }
        #else
        passwords = PasswordManager(settings: settings)
        #endif
        engine.credentialProvider = passwords
        #if DEBUG
        boosts = BoostsController(engine: engine, store: ProcessInfo.processInfo.environment["BEZIER_TEST_VAULT"] == "1" ? BoostStore(directory: nil) : BoostStore())
        #else
        boosts = BoostsController(engine: engine)
        #endif
        engine.downloadDirectory = settings.downloadDirectory
        contents.contentAppearance = settings.websiteAppearance.nsAppearance
        settings.onWebsiteAppearanceChange = { [unowned self] in
            contents.contentAppearance = settings.websiteAppearance.nsAppearance
            for mini in miniWindows { mini.content?.view.appearance = settings.websiteAppearance.nsAppearance }
        }
        model.onChange = { [unowned self] in store.scheduleSave(model) }
        contents.openHandler = { [unowned self] opener, newTab, disposition in
            (activeWindow ?? windows.first)?.handleOpenedTab(opener: opener, newTab: newTab, disposition: disposition)
        }
        downloads.toast = { [unowned self] text, symbol in
            (activeWindow ?? windows.first)?.showToast(text, symbol: symbol)
        }
        contents.urlChangeHandler = { [unowned self] tab in
            for window in windows where window.state.selectedTabID == tab.id { window.refreshDeveloperMode() }
        }
        contents.popupHandler = { [unowned self] content in openMini(content: content) }
        contents.peekEnabled = { [unowned self] in settings.openLinksInPeek }
        contents.peekHandler = { [unowned self] _, content in
            guard let window = activeWindow ?? windows.first else { return }
            window.peek.show(content)
        }
        contents.discardHandler = { [unowned self] tab in
            (activeWindow ?? windows.first)?.discard(tab)
        }
        contents.closeHandler = { [unowned self] tab in
            (activeWindow ?? windows.first)?.closeTab(tab)
        }
        passwords.onManage = { [unowned self] in SettingsWindowController.show(app: self, pane: .passwords) }
        model.autoArchive(protected: [])
        autoArchiveTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runAutoArchive() }
        }
    }

    /// Arc's sidebar, history (optional) and saved passwords (optional). Passwords need the
    /// "Arc Safe Storage" key, so macOS asks the user to allow access once.
    func importFromArc(_ directory: URL = ArcImporter.arcDirectory, options: ArcImportOptions) async -> ArcImportSummary? {
        let wantsHistory = options.history
        guard let arc = await Task.detached(priority: .userInitiated, operation: {
            try? ArcImporter.load(includeHistory: wantsHistory, from: directory)
        }).value else { return nil }
        var summary = model.apply(arc, options: options, history: history)
        if options.passwords {
            let userData = directory.appending(path: "User Data", directoryHint: .isDirectory)
            let decrypted = await Task.detached(priority: .userInitiated) { try? ArcPasswords.readDecrypted(userData: userData) }.value
            if let decrypted {
                summary.passwords = (try? passwords.vault.add(decrypted.logins, neverSave: decrypted.neverSave)) ?? 0
                summary.passwordsFailed = decrypted.failed
            } else {
                summary.passwordsFailed = ArcPasswords.count(userData: userData)
            }
        }
        return summary
    }

    /// Another browser's bookmarks (into the current Space), history and, for Chromium
    /// browsers, saved passwords (macOS asks for its "… Safe Storage" key once).
    func importFrom(_ source: ImportSource, bookmarks: Bool, history wantsHistory: Bool, passwords wantsPasswords: Bool) async -> BrowserImportSummary? {
        guard let data = await Task.detached(priority: .userInitiated, operation: {
            try? BrowserImporter.load(source, includeHistory: wantsHistory)
        }).value else { return nil }
        var summary = BrowserImportSummary()
        if bookmarks, let space = activeWindow?.currentSpace ?? model.spaces.first {
            summary.bookmarks = model.applyBookmarks(data.bookmarks, from: source, into: space)
        }
        if wantsHistory { summary.historyEntries = history.merge(data.history) }
        if wantsPasswords, let chromium = source.chromium {
            let folder = source.dataDirectory
            let decrypted = await Task.detached(priority: .userInitiated) {
                try? ArcPasswords.readDecrypted(userData: folder, service: chromium.service, account: chromium.account)
            }.value
            if let decrypted {
                summary.passwords = (try? passwords.vault.add(decrypted.logins, neverSave: decrypted.neverSave)) ?? 0
                summary.passwordsFailed = decrypted.failed
            }
        }
        return summary
    }

    @discardableResult
    func openWindow() -> BrowserWindowController {
        let controller = BrowserWindowController(app: self, space: activeWindow.map(\.currentSpace))
        windows.append(controller)
        activeWindow = controller
        if !OnboardingController.isCompleted && windows.count == 1 {
            // First launch: the onboarding window shows first and grows into this browser.
            controller.showOnboarding(nil)
        } else {
            controller.showWindow(nil)
        }
        return controller
    }

    // MARK: Mini windows

    /// A link from another app: to the Space an Air Traffic Control rule names, otherwise a
    /// Mini window.
    func openExternal(_ url: URL) {
        if let route = LinkRoute.route(for: url, in: settings.linkRoutes), let space = model.space(route.spaceID) {
            let window = activeWindow ?? windows.first ?? openWindow()
            let tab = model.newTab(url: url, in: space)
            window.switchToSpace(space, selecting: tab)
            window.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        openMini(url: url)
    }

    /// Links from other apps land here. A mini already showing this page just comes forward.
    func openMini(url: URL) {
        if let existing = miniWindows.first(where: { Self.samePage($0.currentURL, url) || Self.samePage($0.initialURL, url) }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let content = engine.makeContent(profile: .default)
        content.load(url)
        present(MiniWindowController(app: self, content: content, initialURL: url))
    }

    /// A page's popup (sign-in windows etc.), already loading.
    func openMini(content: any WebContent) {
        present(MiniWindowController(app: self, content: content, initialURL: content.state.url))
    }

    /// ⌥⌘N: empty mini window with the address field focused.
    func openEmptyMini() {
        present(MiniWindowController(app: self, content: engine.makeContent(profile: .default), initialURL: nil, editing: true))
    }

    private func present(_ mini: MiniWindowController) {
        miniWindows.append(mini)
        mini.showWindow(nil)
        mini.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func miniClosed(_ mini: MiniWindowController) {
        miniWindows.removeAll { $0 === mini }
    }

    /// Same page if scheme-insensitive host, path (ignoring a trailing slash) and query match.
    static func samePage(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        func key(_ u: URL) -> String {
            let host = (u.host() ?? "").lowercased().replacing(/^www\./, with: "")
            var path = u.path(percentEncoded: false)
            if path.hasSuffix("/") { path.removeLast() }
            return host + path + "?" + (u.query() ?? "")
        }
        return key(a) == key(b)
    }

    func windowClosed(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        if activeWindow === controller { activeWindow = windows.last }
    }

    func saveNow() {
        store.saveNow(model)
        history.saveNow()
        downloads.store.save()
    }

    private func runAutoArchive() {
        guard model.autoArchiveAfter > 0 else { return }
        let visible = Set(windows.compactMap { $0.state.selectedTabID })
        for space in model.spaces {
            for tab in space.today where !visible.contains(tab.id)
                && Date.now.timeIntervalSince(tab.lastActiveAt) > model.autoArchiveAfter {
                contents.unload(tab)
            }
        }
        model.autoArchive(protected: visible)
    }
}

#if DEBUG
import CryptoKit

/// In-memory vault key for automation runs (`BEZIER_TEST_VAULT=1`).
@MainActor
final class EphemeralVaultKeyStore: VaultKeyStore {
    private let key = SymmetricKey(size: .bits256)
    func loadOrCreateKey() throws -> SymmetricKey { key }
}
#endif
