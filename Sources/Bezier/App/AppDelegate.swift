import AppKit
import BezierCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var app: AppContext!

    func applicationDidFinishLaunching(_ notification: Notification) {
        app = AppContext()
        NSApp.mainMenu = MainMenu.make()
        if let menu = NSApp.mainMenu { app.shortcuts.apply(to: menu) }
        app.openWindow()
        NSApp.activate()
        #if DEBUG
        Automation.startIfEnabled(app: app)
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.openWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.saveNow()
    }

    /// Links from other apps (once Bezier is the default browser) open in a Mini Bezier window,
    /// like Arc's Little Arc, unless an Air Traffic Control rule sends them to a Space. Opening a
    /// link that's already in a mini focuses that window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { app.openExternal(url) }
    }

    /// View › Appearance: tag 0/1/2 = Automatic/Light/Dark.
    @objc func setWebsiteAppearance(_ sender: NSMenuItem) {
        app.settings.websiteAppearance = BrowserSettings.WebsiteAppearance.allCases[sender.tag]
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setWebsiteAppearance(_:)) {
            item.state = BrowserSettings.WebsiteAppearance.allCases[item.tag] == app.settings.websiteAppearance ? .on : .off
        }
        return true
    }

    @objc func newMiniWindow(_ sender: Any?) {
        app.openEmptyMini()
    }

    @objc func newWindow(_ sender: Any?) {
        app.openWindow()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show(app: app)
    }

    @objc func showPasswords(_ sender: Any?) {
        SettingsWindowController.show(app: app, pane: .passwords)
    }

    @objc func showArcImport(_ sender: Any?) {
        SettingsWindowController.show(app: app, pane: .importer)
    }

    @objc func makeDefaultBrowser(_ sender: Any?) {
        Task { await app.settings.makeDefaultBrowser() }
    }
}
