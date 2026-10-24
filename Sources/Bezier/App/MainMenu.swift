import AppKit

/// Menu bar mirroring Arc's (references/app-bundle/main-menu.md), wired to the responder chain.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let bar = NSMenu()
        bar.addItem(submenu(appMenu()))
        bar.addItem(submenu(fileMenu()))
        bar.addItem(submenu(editMenu()))
        bar.addItem(submenu(viewMenu()))
        bar.addItem(submenu(spacesMenu()))
        bar.addItem(submenu(tabsMenu()))
        bar.addItem(submenu(archiveMenu()))
        let window = windowMenu()
        bar.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("Show Onboarding", #selector(BrowserWindowController.showOnboarding(_:)), ""))
        bar.addItem(submenu(help))
        NSApp.helpMenu = help
        return bar
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Bezier")
        menu.addItem(withTitle: "About Bezier", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(item("Set as Default Browser", #selector(AppDelegate.makeDefaultBrowser(_:)), ""))
        menu.addItem(item("Passwords…", #selector(AppDelegate.showPasswords(_:)), ""))
        menu.addItem(item("Import from Arc…", #selector(AppDelegate.showArcImport(_:)), ""))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Bezier", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Bezier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Tab…", #selector(BrowserWindowController.newTab(_:)), "t"))
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Mini Window", #selector(AppDelegate.newMiniWindow(_:)), "n", [.command, .option]))
        menu.addItem(item("Restore Last Closed Tab", #selector(BrowserWindowController.restoreLastClosedTab(_:)), "t", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Open Command Bar", #selector(BrowserWindowController.openLocation(_:)), "l"))
        menu.addItem(item("Open in Space", #selector(MiniWindowController.openInSpace(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Capture…", #selector(BrowserWindowController.capturePage(_:)), "2", [.command, .shift]))
        menu.addItem(item("Capture in Portrait Mode", #selector(BrowserWindowController.captureInPortraitMode(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        menu.addItem(item("Archive Tab", #selector(BrowserWindowController.archiveTab(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(item("Copy URL", #selector(BrowserWindowController.copyURL(_:)), "c", [.command, .shift]))
        menu.addItem(item("Copy URL as Markdown", #selector(BrowserWindowController.copyURLAsMarkdown(_:)), "c", [.command, .shift, .option]))
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .shift, .option]))
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(BrowserWindowController.showFind(_:)), "f"))
        find.addItem(item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"))
        find.addItem(item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift]))
        find.addItem(item("Use Selection for Find", #selector(BrowserWindowController.useSelectionForFind(_:)), "e"))
        menu.addItem(submenu(find))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let appearance = NSMenu(title: "Appearance")
        let header = NSMenuItem(title: "Websites will use:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        appearance.addItem(header)
        for (i, title) in ["Automatic", "Light", "Dark"].enumerated() {
            let entry = item(title, #selector(AppDelegate.setWebsiteAppearance(_:)), "")
            entry.tag = i
            appearance.addItem(entry)
        }
        menu.addItem(submenu(appearance))
        menu.addItem(.separator())
        menu.addItem(item("Hide Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s"))
        menu.addItem(item("Boost This Site…", #selector(BrowserWindowController.boostThisSite(_:)), "b", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Stop Loading", #selector(BrowserWindowController.stopLoading(_:)), "."))
        menu.addItem(item("Reload This Page", #selector(BrowserWindowController.reloadPage(_:)), "r"))
        menu.addItem(item("Force Reload This Page", #selector(BrowserWindowController.forceReloadPage(_:)), "r", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(BrowserWindowController.zoomReset(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "="))
        menu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+", hidden: true))
        menu.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        let developer = NSMenu(title: "Developer")
        developer.addItem(item("View Source", #selector(BrowserWindowController.viewSource(_:)), "u", [.command, .option]))
        developer.addItem(item("Developer Tools", #selector(BrowserWindowController.showDevTools(_:)), "i", [.command, .option]))
        developer.addItem(item("Inspect Elements", #selector(BrowserWindowController.inspectElement(_:)), "c", [.command, .option]))
        developer.addItem(item("JavaScript Console", #selector(BrowserWindowController.showConsole(_:)), "j", [.command, .option]))
        developer.addItem(item("Network Inspector", #selector(BrowserWindowController.showNetwork(_:)), ""))
        developer.addItem(.separator())
        developer.addItem(item("Toggle Developer Mode", #selector(BrowserWindowController.toggleDeveloperMode(_:)), "d", [.control]))
        developer.addItem(.separator())
        developer.addItem(item("Clear Cookies and Refresh", #selector(BrowserWindowController.clearCookiesAndRefresh(_:)), ""))
        developer.addItem(item("Clear Cache and Refresh", #selector(BrowserWindowController.clearCacheAndRefresh(_:)), ""))
        menu.addItem(submenu(developer))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func spacesMenu() -> NSMenu {
        let menu = NSMenu(title: "Spaces")
        menu.addItem(item("New Space…", #selector(BrowserWindowController.newSpace(_:)), ""))
        menu.addItem(item("Edit Theme…", #selector(BrowserWindowController.editThemeOfCurrentSpace(_:)), ""))
        menu.addItem(item("Change Icon…", #selector(BrowserWindowController.changeIconOfCurrentSpace(_:)), ""))
        menu.addItem(item("Rename Space", #selector(BrowserWindowController.renameCurrentSpace(_:)), ""))
        menu.addItem(item("Delete Space…", #selector(BrowserWindowController.deleteCurrentSpace(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Manage Spaces…", #selector(BrowserWindowController.showSpacesLibrary(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Next Space", #selector(BrowserWindowController.nextSpace(_:)), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command, .option]))
        menu.addItem(item("Previous Space", #selector(BrowserWindowController.previousSpace(_:)), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command, .option]))
        menu.addItem(.separator())
        for i in 0..<9 {
            let space = item("Space \(i + 1)", #selector(BrowserWindowController.selectSpaceAtIndex(_:)), "\(i + 1)", [.control])
            space.tag = i
            menu.addItem(space)
        }
        return menu
    }

    private static func tabsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tabs")
        menu.addItem(item("New Tab…", #selector(BrowserWindowController.newTab(_:)), "t", hidden: true))
        menu.addItem(item("Pin/Unpin Tab", #selector(BrowserWindowController.togglePinSelected(_:)), "d"))
        menu.addItem(item("Add to Favorites", #selector(BrowserWindowController.addSelectedToFavorites(_:)), ""))
        menu.addItem(item("New Folder…", #selector(BrowserWindowController.newFolder(_:)), "n", [.command, .option, .shift]))
        menu.addItem(item("Duplicate", #selector(BrowserWindowController.duplicateSelected(_:)), ""))
        menu.addItem(item("Rename Current Item", #selector(BrowserWindowController.renameSelected(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Next Tab", #selector(BrowserWindowController.nextTab(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), [.command, .option]))
        menu.addItem(item("Previous Tab", #selector(BrowserWindowController.previousTab(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command, .option]))
        menu.addItem(item("Next Tab", #selector(BrowserWindowController.nextTab(_:)), "]", [.command, .shift], hidden: true))
        menu.addItem(item("Previous Tab", #selector(BrowserWindowController.previousTab(_:)), "[", [.command, .shift], hidden: true))
        for i in 0..<9 {
            let tab = item("Tab \(i + 1)", #selector(BrowserWindowController.selectTabAtIndex(_:)), "\(i + 1)", hidden: true)
            tab.tag = i
            menu.addItem(tab)
        }
        menu.addItem(.separator())
        menu.addItem(item("Collapse All Folders", #selector(BrowserWindowController.collapseAllFolders(_:)), ""))
        menu.addItem(item("Expand All Folders", #selector(BrowserWindowController.expandAllFolders(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Clear Unpinned Tabs", #selector(BrowserWindowController.clearToday(_:)), "k", [.command, .shift]))
        return menu
    }

    private static func archiveMenu() -> NSMenu {
        let menu = NSMenu(title: "Archive")
        menu.addItem(item("Go Back", #selector(BrowserWindowController.goBack(_:)), "["))
        menu.addItem(item("Go Forward", #selector(BrowserWindowController.goForward(_:)), "]"))
        menu.addItem(.separator())
        menu.addItem(item("View History", #selector(BrowserWindowController.showHistory(_:)), "y"))
        menu.addItem(item("View Archive", #selector(BrowserWindowController.showArchive(_:)), ""))
        menu.addItem(item("Restore Last Closed Tab", #selector(BrowserWindowController.restoreLastClosedTab(_:)), ""))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(item("View Library", #selector(BrowserWindowController.toggleLibrary(_:)), "l", [.command, .shift]))
        menu.addItem(item("View Downloads", #selector(BrowserWindowController.showDownloads(_:)), "j", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command], hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // Hidden items still fire their shortcut (alternate bindings like ⌘+ and ⌘1–9).
        item.isHidden = hidden
        item.allowsKeyEquivalentWhenHidden = hidden
        return item
    }
}
