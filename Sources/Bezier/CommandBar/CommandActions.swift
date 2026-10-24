import AppKit
import BezierCore
import BezierEngine

/// Something the Command Bar can do. Titles are contextual ("Pin Tab" vs "Unpin Tab"), the way
/// Arc's are, and keywords catch what people type ("devtools", "favourite", "close").
@MainActor
struct CommandAction {
    let id: String
    let title: String
    let keywords: [String]
    let symbol: String
    let shortcut: String?
    let run: (BrowserWindowController) -> Void
}

/// Arc-style action list, built fresh for the current window state each time the bar opens.
/// Source of names and shortcuts: references/app-bundle/main-menu.md.
@MainActor
enum CommandActions {
    static func available(in browser: BrowserWindowController) -> [CommandAction] {
        var actions: [CommandAction] = []
        func add(_ id: String, _ title: String, _ symbol: String, _ shortcut: String? = nil,
                 _ keywords: [String] = [], _ run: @escaping (BrowserWindowController) -> Void) {
            actions.append(CommandAction(id: id, title: title, keywords: keywords, symbol: symbol, shortcut: shortcut, run: run))
        }

        let model = browser.model
        let tab = browser.selectedTab
        let location = tab.flatMap(model.location(of:))
        let content = browser.selectedContent

        // Current tab
        if let tab {
            switch location {
            case .today?:
                add("pin", "Pin Tab", "pin", "⌘D", ["pinned", "keep"]) { $0.togglePinSelected(nil) }
            case .pinned?:
                add("unpin", "Unpin Tab", "pin.slash", "⌘D", ["unpinned"]) { $0.togglePinSelected(nil) }
            default: break
            }
            if location == .favorite {
                add("unfavorite", "Remove from Favorites", "star.slash", nil, ["favourite", "unfavorite"]) { b in
                    if let t = b.selectedTab { b.removeFromFavorites(t) }
                }
            } else {
                add("favorite", "Add to Favorites", "star", nil, ["favourite", "fav", "star", "bookmark"]) {
                    $0.addSelectedToFavorites(nil)
                }
            }
            let isToday: Bool = { if case .today? = location { return true } else { return false } }()
            add("archive", isToday ? "Archive Tab" : "Unload Tab", "archivebox", "⌘W", ["close tab", "close"]) {
                $0.archiveTab(nil)
            }
            add("duplicate", "Duplicate Tab", "plus.square.on.square", nil, ["copy tab", "clone"]) { $0.duplicateSelected(nil) }
            add("rename", "Rename Tab", "pencil", nil, ["title"]) { $0.renameSelected(nil) }
            add("copy-url", "Copy URL", "link", "⇧⌘C", ["copy link", "share"]) { $0.copyURL(nil) }
            add("copy-markdown", "Copy URL as Markdown", "text.badge.plus", "⌥⇧⌘C", ["copy link", "md"]) {
                $0.copyURLAsMarkdown(nil)
            }
            if tab.pinnedURL != nil && tab.hasDriftedFromPinnedURL {
                add("reset", "Reset Tab to Original URL", "arrow.uturn.backward", nil, ["pinned", "home"]) { b in
                    if let t = b.selectedTab { b.resetToPinnedURL(t) }
                }
            }
            for space in model.spaces where space.id != browser.state.spaceID {
                add("move-\(space.id)", "Move Tab to \(space.title)", "arrow.right.square", nil, ["send", "space"]) { b in
                    if let t = b.selectedTab { b.move(t, to: space) }
                }
            }
        }

        // Page
        if content != nil {
            if let tab, let splitID = tab.splitID {
                let stacked = tab.splitStacked
                add("split-arrange", stacked ? "Arrange Split Side by Side" : "Arrange Split Top to Bottom",
                    stacked ? "rectangle.split.2x1" : "rectangle.split.1x2", nil, ["split view", "vertical", "horizontal", "stack"]) {
                    $0.toggleSplitArrangement(splitID)
                }
                add("split-separate", "Separate Split View", "rectangle", nil, ["split view", "unsplit"]) { $0.separateSplit(splitID) }
            }
            add("reload", "Reload Page", "arrow.clockwise", "⌘R", ["refresh"]) { $0.reloadPage(nil) }
            add("force-reload", "Force Reload Page", "arrow.clockwise.circle", "⇧⌘R", ["hard refresh", "hard reload"]) {
                $0.forceReloadPage(nil)
            }
            add("zoom-in", "Zoom In", "plus.magnifyingglass", "⌘+", ["bigger", "larger"]) { $0.zoomIn(nil) }
            add("zoom-out", "Zoom Out", "minus.magnifyingglass", "⌘−", ["smaller"]) { $0.zoomOut(nil) }
            add("zoom-reset", "Actual Size", "1.magnifyingglass", "⌘0", ["zoom reset", "reset zoom"]) { $0.zoomReset(nil) }
        }

        // Developer
        if let content {
            let dev = ["developer", "dev"]
            if let url = content.state.url, DeveloperMode.siteKey(url) != nil {
                let on = browser.app.settings.isDeveloperMode(url)
                add("dev-mode", on ? "Turn Off Developer Mode for This Site" : "Turn On Developer Mode for This Site",
                    "chevron.left.forwardslash.chevron.right", "⌃D", dev + ["developer mode", "dev mode", "localhost"]) {
                    $0.toggleDeveloperMode(nil)
                }
            }
            add("capture", "Capture Page", "camera.viewfinder", "⇧⌘2", ["screenshot", "capture"]) { $0.capturePage(nil) }
            add("portrait", "Capture in Portrait Mode", "photo.artframe", nil, ["screenshot", "background", "pretty", "share image"]) {
                $0.captureInPortraitMode(nil)
            }
            if content.supports(.showNetwork) {
                add("network", "Network Inspector", "network", nil, dev + ["requests", "resources"]) { $0.showNetwork(nil) }
            }
            if content.supports(.showDevTools) {
                add("devtools", "Developer Tools", "hammer", "⌥⌘I", dev + ["devtools", "web inspector", "inspector", "debug"]) {
                    $0.showDevTools(nil)
                }
            }
            if content.supports(.showConsole) {
                add("console", "JavaScript Console", "terminal", "⌥⌘J", dev + ["console", "log", "js"]) { $0.showConsole(nil) }
            }
            if content.supports(.inspectElement) {
                add("inspect", "Inspect Elements", "cursorarrow.rays", "⌥⌘C", dev + ["element", "picker", "inspect"]) {
                    $0.inspectElement(nil)
                }
            }
            if content.state.url?.scheme?.hasPrefix("http") == true {
                add("view-source", "View Source", "chevron.left.forwardslash.chevron.right", "⌥⌘U", dev + ["html", "source code"]) {
                    $0.viewSource(nil)
                }
            }
            if content.supports(.clearCookiesAndReload) {
                add("clear-cookies", "Clear Cookies and Refresh", "trash", nil, dev + ["cookies", "site data", "log out"]) {
                    $0.clearCookiesAndRefresh(nil)
                }
            }
            if content.supports(.clearCacheAndReload) {
                add("clear-cache", "Clear Cache and Refresh", "trash.circle", nil, dev + ["cache", "empty cache"]) {
                    $0.clearCacheAndRefresh(nil)
                }
            }
        }

        // Tabs & folders
        add("restore", "Restore Last Closed Tab", "arrow.uturn.backward", "⇧⌘T", ["reopen", "undo close", "archive"]) {
            $0.restoreLastClosedTab(nil)
        }
        add("clear", "Clear Unpinned Tabs", "arrow.down.to.line", "⇧⌘K", ["archive all", "clean up", "close all"]) {
            $0.clearToday(nil)
        }
        add("next-tab", "Next Tab", "chevron.down", "⌥⌘↓", ["switch"]) { $0.nextTab(nil) }
        add("prev-tab", "Previous Tab", "chevron.up", "⌥⌘↑", ["switch"]) { $0.previousTab(nil) }
        add("new-folder", "New Folder", "folder.badge.plus", "⌥⇧⌘N", ["group"]) { $0.newFolder(nil) }
        add("collapse-folders", "Collapse All Folders", "folder", nil, ["close folders"]) { $0.collapseAllFolders(nil) }
        add("expand-folders", "Expand All Folders", "folder.fill", nil, ["open folders"]) { $0.expandAllFolders(nil) }

        // Spaces
        for (index, space) in model.spaces.enumerated() where space.id != browser.state.spaceID {
            add("space-\(space.id)", "Switch to \(space.title)", "square.stack", index < 9 ? "⌃\(index + 1)" : nil,
                ["space", "go to", space.icon ?? ""]) { $0.switchToSpace(space) }
        }
        add("next-space", "Next Space", "arrow.right.square", "⌥⌘→", ["space"]) { $0.nextSpace(nil) }
        add("prev-space", "Previous Space", "arrow.left.square", "⌥⌘←", ["space"]) { $0.previousSpace(nil) }
        add("new-space", "New Space", "plus.rectangle.on.rectangle", nil, ["create space"]) { $0.newSpace(nil) }
        for (name, theme) in SpaceTheme.named {
            add("theme-\(name)", "Space Theme: \(name)", "paintbrush", nil, ["color", "colour", "theme", "appearance"]) { b in
                b.setTheme(theme, for: b.currentSpace)
            }
        }

        // Library & app
        add("library", "Open Library", "archivebox", "⇧⌘L", ["collections", "box"]) { $0.openLibrary($0.state.librarySection) }
        add("archive-view", "View Archive", "archivebox", nil, ["archived tabs", "closed tabs"]) { $0.openLibrary(.archive) }
        add("history", "View History", "clock.arrow.circlepath", "⌘Y", ["visited", "recent"]) { $0.openLibrary(.history) }
        add("downloads", "View Downloads", "arrow.down.circle", "⇧⌘J", ["files"]) { $0.openLibrary(.downloads) }
        add("spaces-library", "Manage Spaces", "square.stack", nil, ["spaces"]) { $0.openLibrary(.spaces) }
        add("settings", "Settings", "gearshape", "⌘,", ["preferences", "options"]) { _ in
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        }
        if Boost.domain(for: browser.selectedTab?.url) != nil {
            let editing = browser.app.boosts.store.boost(for: browser.selectedTab?.url) != nil
            add("boost", editing ? "Edit Boost" : "Boost This Site", "paintbrush.pointed", "⌥⌘B",
                ["boost", "customize", "css", "zap", "restyle", "font", "colors", "colours"]) { $0.boostThisSite(nil) }
        }
        add("find", "Find on Page", "text.magnifyingglass", "⌘F", ["search page", "find in page", "search in page"]) { $0.showFind(nil) }
        add("passwords", "Show Passwords", "key", nil, ["passwords", "logins", "keychain", "autofill"]) { _ in
            NSApp.sendAction(#selector(AppDelegate.showPasswords(_:)), to: nil, from: nil)
        }
        if ArcImporter.isInstalled {
            add("import-arc", "Import from Arc", "square.and.arrow.down", nil, ["migrate", "arc", "move", "bring tabs", "passwords"]) { _ in
                NSApp.sendAction(#selector(AppDelegate.showArcImport(_:)), to: nil, from: nil)
            }
        }
        if !browser.app.settings.isDefaultBrowser {
            add("default-browser", "Set as Default Browser", "star.circle", nil, ["default"]) { _ in
                NSApp.sendAction(#selector(AppDelegate.makeDefaultBrowser(_:)), to: nil, from: nil)
            }
        }

        // Current Space
        let space = browser.currentSpace
        add("edit-theme", "Edit Theme", "paintbrush", nil, ["color", "colour", "space theme", "gradient"]) { $0.editSpace(space, panel: .theme) }
        add("change-icon", "Change Space Icon", "face.smiling", nil, ["emoji", "icon"]) { $0.editSpace(space, panel: .icon) }
        add("rename-space", "Rename Space", "pencil", nil, ["space name"]) { $0.beginRenameSpace(space) }
        if model.spaces.count > 1 {
            add("delete-space", "Delete Space", "trash", nil, ["remove space"]) { $0.confirmDelete(space) }
        }

        // Window
        add("sidebar", browser.state.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", "sidebar.left", "⌘S",
            ["toggle sidebar", "focus", "zen"]) { $0.toggleSidebar(nil) }
        add("new-mini", "New Mini Window", "macwindow", "⌥⌘N", ["little arc", "mini", "quick"]) { _ in
            NSApp.sendAction(#selector(AppDelegate.newMiniWindow(_:)), to: nil, from: nil)
        }
        add("new-window", "New Window", "macwindow.badge.plus", "⌘N", ["window"]) { _ in
            NSApp.sendAction(#selector(AppDelegate.newWindow(_:)), to: nil, from: nil)
        }
        add("fullscreen", "Toggle Full Screen", "arrow.up.left.and.arrow.down.right", "⌃⌘F", ["full screen", "fullscreen"]) {
            $0.window?.toggleFullScreen(nil)
        }
        add("minimize", "Minimize Window", "minus.square", "⌘M", ["hide window"]) { $0.window?.miniaturize(nil) }
        return actions
    }
}

/// Ranks how well a query matches a title and its keywords. Higher is better; nil means no match.
enum CommandMatcher {
    static func score(query: String, title: String, keywords: [String] = []) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let t = title.lowercased()
        if t == q { return 120 }
        if t.hasPrefix(q) { return 100 }
        let titleWords = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let keywordWords = keywords.flatMap { $0.lowercased().split(separator: " ").map(String.init) }
        let tokens = q.split(separator: " ").map(String.init)
        if tokens.allSatisfy({ tok in titleWords.contains { $0.hasPrefix(tok) } }) { return 88 }
        if keywords.contains(where: { $0.lowercased().hasPrefix(q) }) { return 80 }
        if tokens.allSatisfy({ tok in (titleWords + keywordWords).contains { $0.hasPrefix(tok) } }) { return 72 }
        if q.count >= 3 && t.contains(q) { return 58 }
        return nil
    }
}

extension SpaceTheme {
    static let named: [(String, SpaceTheme)] = [
        ("Neutral", .neutral), ("Lavender", .lavender), ("Coral", .coral), ("Sky", .sky), ("Mint", .mint), ("Sand", .sand), ("Graphite", .graphite),
    ]
}
