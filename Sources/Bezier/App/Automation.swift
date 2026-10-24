#if DEBUG
import AppKit
import BezierCore
import SwiftUI
import WebKit

/// Debug-only remote control for UI testing without global keystrokes. Enabled with
/// `BEZIER_AUTOMATION=1`; driven by `scripts/bezierctl` via distributed notifications:
///   action:<selector>   send an action down the responder chain (e.g. action:toggleSidebar:)
///   key:<mods>+<char>   deliver a key equivalent to Bezier's window only (e.g. key:cmd+s)
///   cmdbar:<text>       open the Command Bar with a query
///   reveal              slide out the hidden sidebar
///   open:<url>          open a URL in a new tab
///   child:<url>         open a URL as if the selected page opened it (target=_blank)
///   mini:<url>          open a URL the way links from other apps do
///   glass:<0…1>         set the current Space's Glass (translucency)
///   appearance:<automatic|light|dark>  set the current Space's appearance
///   dropspace           delete the current Space (no confirmation; for test cleanup)
///   click:x,y[,n]       click (n times) at front-window coordinates, top-left origin
///   drag:x1,y1,x2,y2[,s] drag with the mouse in the front window, top-left origin; hold s seconds
///   scrolltest:<s>      scroll the page down and back up with trackpad-style events for s seconds
///   backdrop:<on|off>   show or hide the window's glass backdrop
///   js:<code>           run JavaScript in the selected page and print the result
///   popoverkey:<return|escape>  press a key in the open popover
///   find:<text> / findinfo  search the page / print the match position
///   vaultinfo / panelinfo  print saved sites and usernames (never passwords) / autofill list windows
///   dragsim:<i>:<dy>[:drop]  move Today row i by dy points with the sidebar drag logic; :drop lets go
@MainActor
enum Automation {
    static let notification = Notification.Name("app.bezier.automation")

    static func startIfEnabled(app: AppContext) {
        guard ProcessInfo.processInfo.environment["BEZIER_AUTOMATION"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { run(command, app: app) }
        }
        print("[automation] listening")
    }

    private static func run(_ command: String, app: AppContext) {
        let window = app.activeWindow?.window
        // Onboarding's own window while it shows (Bezier may not be the active app, so no key window).
        let frontWindow = NSApp.windows.first { $0 is OnboardingWindow && $0.isVisible } ?? NSApp.keyWindow
        if command.hasPrefix("cmdbar:") {
            app.activeWindow?.debugShowCommandBar(query: String(command.dropFirst("cmdbar:".count)))
        } else if command.hasPrefix("open:"), let url = URL(string: String(command.dropFirst("open:".count))) {
            app.activeWindow?.openInNewTab(url)
        } else if command.hasPrefix("child:"), let url = URL(string: String(command.dropFirst("child:".count))),
                  let browser = app.activeWindow, let opener = browser.selectedTab {
            // Same path as a page opening a target=_blank link.
            let tab = app.model.openChild(url: url, from: opener, in: browser.currentSpace)
            browser.select(tab)
        } else if command.hasPrefix("mini:"), let url = URL(string: String(command.dropFirst("mini:".count))) {
            app.openMini(url: url)
            print("[automation] minis=\(app.miniWindows.count)")
        } else if command.hasPrefix("glass:"), let value = Double(command.dropFirst("glass:".count)), let browser = app.activeWindow {
            var theme = browser.currentSpace.theme
            theme.translucency = value
            browser.setTheme(theme, for: browser.currentSpace)
        } else if command.hasPrefix("appearance:"), let browser = app.activeWindow,
                  let value = SpaceTheme.Appearance(rawValue: String(command.dropFirst("appearance:".count))) {
            var theme = browser.currentSpace.theme
            theme.appearance = value
            browser.setTheme(theme, for: browser.currentSpace)
        } else if command == "dropemptylastspace", let browser = app.activeWindow, let last = app.model.spaces.last,
                  app.model.spaces.count > 1, last.today.isEmpty, last.pinned.isEmpty {
            // Test cleanup that can't lose anything: only an empty trailing Space goes.
            if browser.state.spaceID == last.id { browser.switchToSpace(app.model.spaces[0]) }
            app.model.delete(last)
            print("[automation] dropped empty space")
        } else if command == "dropspace", let browser = app.activeWindow {
            // Test cleanup: delete the current Space without the confirmation sheet.
            let space = browser.currentSpace
            if app.model.delete(space) { browser.switchToSpace(app.model.spaces[0]) }
        } else if command.hasPrefix("keydown:"), let code = UInt16(command.dropFirst("keydown:".count)),
                  let window = NSApp.windows.first(where: { $0 is OnboardingWindow && $0.isVisible }) ?? window {
            // Key press delivered to Bezier's first responder only (e.g. 124 = →).
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                            isARepeat: false, keyCode: code) {
                window.sendEvent(event)
            }
        } else if command.hasPrefix("draghint:") || command.hasPrefix("testdrop:"), let browser = app.activeWindow {
            // draghint|testdrop:<left|right|center>:<draggedIndex>:<targetIndex> over the current Space's Today list.
            let parts = command.split(separator: ":").map(String.init)
            let today = browser.currentSpace.today
            guard parts.count == 4, let d = Int(parts[2]), let t = Int(parts[3]), today.indices.contains(d), today.indices.contains(t) else { return }
            let zone: DropZone = parts[1] == "left" ? .left : (parts[1] == "right" ? .right : .center)
            if parts[0] == "draghint" {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) {
                    browser.state.drag.draggingID = today[d].id
                    browser.state.drag.translation = CGSize(width: 18, height: -10)
                    browser.state.drag.hoverTarget = today[t].id
                    browser.state.drag.hoverZone = zone
                }
            } else {
                _ = browser.state.drag.end()
                browser.handleSidebarDrop(today[d].id, .onto(DropTarget(frame: .zero, kind: .today, leftTabID: today[t].id, rightTabID: today[t].id, owner: UUID()), zone))
            }
        } else if command.hasPrefix("dragsim:"), let browser = app.activeWindow {
            // dragsim:<todayIndex>:<dy>[:drop] lifts a Today row and moves it dy points through the
            // sidebar's drag logic (not the gesture); with :drop it lets go.
            let parts = command.split(separator: ":").map(String.init)
            let today = browser.currentSpace.today
            let drag = browser.state.drag
            guard parts.count >= 3, let i = Int(parts[1]), let dy = Double(parts[2]), today.indices.contains(i),
                  let frame = drag.targets[today[i].id]?.frame else { return }
            drag.update(dragging: today[i].id, translation: CGSize(width: 0, height: dy),
                        location: CGPoint(x: frame.midX, y: frame.midY + dy))
            if parts.count > 3, let drop = drag.end() { browser.handleSidebarDrop(drop.dragged, drop.drop) }
            print("[automation] \(command) exit=\(String(describing: drag.groupExit))")
        } else if command.hasPrefix("popoverkey:") {
            // popoverkey:<return|escape> presses a key in the open popover (e.g. Save Password).
            guard let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) else {
                print("[automation] no popover"); return
            }
            let isReturn = command.hasSuffix("return")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: popover.windowNumber, context: nil, characters: isReturn ? "\r" : "\u{1b}",
                                                charactersIgnoringModifiers: isReturn ? "\r" : "\u{1b}", isARepeat: false, keyCode: isReturn ? 36 : 53) {
                    // Default and cancel buttons answer key equivalents, which need no key window.
                    if type == .keyDown, popover.contentView?.performKeyEquivalent(with: event) == true { break }
                    popover.sendEvent(event)
                }
            }
            print("[automation] \(command)")
        } else if command == "vaultinfo" {
            // Counts only: sites and usernames are printed, never passwords.
            let vault = app.passwords.vault
            print("[automation] vault: \(vault.logins.map { "\($0.host)/\($0.username) used \($0.timesUsed)" }) never: \(vault.neverSave.sorted())")
        } else if command == "whereami", let browser = app.activeWindow {
            print("[automation] space: \(browser.currentSpace.title) (\(app.model.spaces.firstIndex { $0 === browser.currentSpace } ?? -1) of \(app.model.spaces.count)) today: \(browser.currentSpace.today.count)")
        } else if command.hasPrefix("find:"), let browser = app.activeWindow {
            // find:<text> opens the find bar with a query (it searches as if typed).
            browser.showFind(nil)
            browser.state.find.query = String(command.dropFirst(5))
        } else if command == "findinfo", let browser = app.activeWindow {
            let find = browser.state.find
            print("[automation] find: visible=\(find.isVisible) '\(find.query)' \(find.current) of \(find.total)")
        } else if command.hasPrefix("dragto:"), let browser = app.activeWindow {
            // dragto:<from>:<to>:<fy>[:<fx>] drags Today row `from` to a point in row `to`'s frame
            // (fractions of its height and width) and lets go. `to` = -1 targets the New Tab row.
            let parts = command.split(separator: ":").map(String.init)
            let space = browser.currentSpace, today = space.today, drag = browser.state.drag
            guard parts.count >= 4, let i = Int(parts[1]), let j = Int(parts[2]), let fy = Double(parts[3]), today.indices.contains(i),
                  let from = drag.targets[today[i].id]?.frame ?? drag.targets.values.first(where: { $0.leftTabID == today[i].id })?.frame
            else { return }
            let targetID = j < 0 ? space.id : today[j].id
            guard let to = drag.targets[targetID]?.frame ?? drag.targets.values.first(where: { $0.leftTabID == targetID || $0.rightTabID == targetID })?.frame else { return }
            let fx = parts.count > 4 ? Double(parts[4]) ?? 0.5 : 0.5
            let point = CGPoint(x: to.minX + to.width * fx, y: to.minY + to.height * fy)
            drag.update(dragging: today[i].id, translation: CGSize(width: point.x - from.midX, height: point.y - from.midY), location: point)
            let zone = drag.hoverZone
            if let drop = drag.end() { browser.handleSidebarDrop(drop.dragged, drop.drop) }
            print("[automation] \(command) zone=\(String(describing: zone))")
        } else if command.hasPrefix("switcher:"), let browser = app.activeWindow {
            // switcher:<next|back|commit|cancel> drives the ⌃Tab switcher as if keys were held.
            switch command.dropFirst("switcher:".count) {
            case "next": browser.advanceTabSwitcher(backwards: false)
            case "back": browser.advanceTabSwitcher(backwards: true)
            case "commit": browser.commitTabSwitcher()
            default: browser.endTabSwitcher()
            }
            print("[automation] \(command) active=\(browser.isTabSwitcherActive) selected=\(browser.selectedTab?.url?.lastPathComponent ?? "-") cards=\(browser.state.switcher.items.count) thumbs=\(browser.state.switcher.items.filter { $0.thumbnail != nil }.count)")
        } else if command.hasPrefix("peek"), let browser = app.activeWindow {
            // peek (info) / peek:open / peek:close
            if command == "peek:open" { browser.peek.openAsTab() }
            if command == "peek:close" { browser.peek.close() }
            print("[automation] \(command) showing=\(browser.peek.isShowing) url=\(browser.peek.content?.state.url?.absoluteString ?? "-") selected=\(browser.selectedTab?.url?.absoluteString ?? "-")")
        } else if command.hasPrefix("selecttab:"), let browser = app.activeWindow {
            // selecttab:<pinned|today>:<index> in the current Space (never Favorites).
            let parts = command.split(separator: ":").map(String.init)
            let space = browser.currentSpace
            let tabs = parts.count > 1 && parts[1] == "pinned" ? space.allPinnedTabs : space.today
            if parts.count > 2, let i = Int(parts[2]), tabs.indices.contains(i) { browser.select(tabs[i]) }
            print("[automation] \(command) selected=\(browser.selectedTab?.url?.lastPathComponent ?? "-")")
        } else if command.hasPrefix("swipetest:"), let browser = app.activeWindow, let window = browser.window,
                  let dx = Double(command.dropFirst("swipetest:".count)) {
            // swipetest:<dx> two-finger horizontal swipe over the sidebar (began, changed…, ended).
            let point = browser.root.convert(NSPoint(x: browser.root.sidebarFrame.midX, y: browser.root.sidebarFrame.midY), to: nil)
            let steps = 12
            for i in 0...(steps + 1) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) {
                    MainActor.assumeIsolated {
                        let phase: Int64 = i == 0 ? 1 : (i > steps ? 4 : 2)          // began, changed, ended
                        let delta = i == 0 || i > steps ? 0 : Int32(dx / Double(steps))
                        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                               wheel1: 0, wheel2: delta, wheel3: 0) else { return }
                        let screen = window.convertPoint(toScreen: point)
                        cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
                        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                        if let event = NSEvent(cgEvent: cg) {
                            if i == 1 {
                                let inSidebar = browser.root.sidebarFrame.contains(browser.root.convert(event.locationInWindow, from: nil))
                                print("[automation] swipe event phase=\(event.phase.rawValue) dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) inverted=\(event.isDirectionInvertedFromDevice) inSidebar=\(inSidebar)")
                            }
                            window.sendEvent(event)
                        }
                        if i > steps { print("[automation] swipe done offset=\(browser.state.spaceSwipeOffset)") }
                    }
                }
            }
        } else if command.hasPrefix("cmdkey:"), let browser = app.activeWindow {
            // cmdkey:<tab|delete|state> presses a key in the open Command Bar and prints its state.
            print("[automation] cmdbar \(browser.debugCommandBar(String(command.dropFirst("cmdkey:".count))))")
        } else if command.hasPrefix("cmdtype:"), let browser = app.activeWindow {
            // cmdtype:<text> replaces the open Command Bar's text.
            browser.debugSetCommandBarQuery(String(command.dropFirst("cmdtype:".count)))
        } else if command.hasPrefix("boost:"), let browser = app.activeWindow {
            // boost:css:<css> / boost:hue:<deg> / boost:zap / boost:info for the selected page's site.
            let parts = command.split(separator: ":", maxSplits: 2).map(String.init)
            let store = app.boosts.store
            guard let url = browser.selectedTab?.url, let domain = Boost.domain(for: url) else { return }
            var boost = store.boost(for: url) ?? Boost(domain: domain)
            switch parts.count > 1 ? parts[1] : "info" {
            case "css": boost.css = parts.count > 2 ? parts[2] : ""; store.save(boost)
            case "hue": boost.hue = Double(parts.count > 2 ? parts[2] : "0") ?? 0; store.save(boost)
            case "zap":
                browser.selectedContent?.beginZap { selector in
                    if let selector { var b = store.boost(for: url) ?? Boost(domain: domain); b.zapped.append(selector); store.save(b) }
                    print("[automation] zapped \(selector ?? "nil (ended)")")
                }
            case "unzap": browser.selectedContent?.endZap()
            case "editor": browser.boostThisSite(nil)
            default: break
            }
            let current = store.boost(for: url)
            print("[automation] boost \(current?.domain ?? "-") zapped=\(current?.zapped ?? []) css=\(current?.css.count ?? 0) chars")
        } else if command.hasPrefix("media"), let browser = app.activeWindow {
            // media (info) / media:mute / media:toggle for the current Space's tabs only.
            let tabs = browser.currentSpace.today + browser.currentSpace.allPinnedTabs
            if command == "media:mute" || command == "media:toggle", let tab = tabs.first(where: { app.media.states[$0.id] != nil }) {
                let muted = app.media.states[tab.id]?.isMuted ?? false
                app.contents.existingContent(for: tab)?.perform(command == "media:mute" ? .setMuted(!muted) : .togglePlayback)
            }
            let rows = tabs.compactMap { tab in app.media.states[tab.id].map { "\(tab.url?.lastPathComponent ?? "?"): playing=\($0.isPlaying) muted=\($0.isMuted)" } }
            let mini = app.media.miniPlayerTab(excluding: browser.state.selectedTabID).flatMap(app.model.tab(id:))?.url?.lastPathComponent ?? "-"
            print("[automation] media \(rows) miniPlayer=\(mini)")
        } else if command.hasPrefix("capturetest:"), let content = app.activeWindow?.selectedContent {
            // capturetest:<full|visible|area>:<path> writes the capture to a file (not Downloads).
            let parts = command.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            Task { @MainActor in
                let image: NSImage? = switch parts[1] {
                case "full": await content.fullPageSnapshot()
                case "area": await content.snapshot(of: CGRect(x: 20, y: 20, width: 300, height: 200))
                default: await content.snapshot()
                }
                guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    print("[automation] capture failed"); return
                }
                try? png.write(to: URL(filePath: parts[2]))
                print("[automation] capture \(parts[1]) \(Int(image.size.width))x\(Int(image.size.height))")
            }
        } else if command == "splitstack", let browser = app.activeWindow, let splitID = browser.selectedTab?.splitID {
            browser.toggleSplitArrangement(splitID)
            print("[automation] split stacked=\(browser.selectedTab?.splitStacked ?? false)")
        } else if command.hasPrefix("shortcut:"), let menu = NSApp.mainMenu {
            // shortcut:<selector>:<key>:<cmd,shift,…> sets one; shortcut:reset puts all back.
            let parts = command.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2, parts[1] == "reset" { app.shortcuts.resetAll(in: menu) }
            if parts.count >= 4 {
                var flags: NSEvent.ModifierFlags = []
                for name in parts[3].split(separator: ",") {
                    switch name { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift)
                    case "opt": flags.insert(.option); case "ctrl": flags.insert(.control); default: break }
                }
                app.shortcuts.set(.init(key: parts[2], modifiers: flags), for: parts[1] + ":#0", in: menu)
            }
            let describe = { (selector: String) -> String in
                guard let item = ShortcutStore.items(in: menu).first(where: { $0.action.map(NSStringFromSelector) == selector && !$0.isHidden }) else { return "?" }
                return ShortcutStore.describe(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
            }
            print("[automation] shortcuts find=\(describe("showFind:")) boost=\(describe("boostThisSite:")) overrides=\(app.shortcuts.overrides.count)")
        } else if command.hasPrefix("profile:"), let browser = app.activeWindow {
            browser.setProfile(String(command.dropFirst("profile:".count)), for: browser.currentSpace)
            print("[automation] profile \(browser.currentSpace.profile) profiles=\(app.model.profiles)")
        } else if command.hasPrefix("route:"), let browser = app.activeWindow {
            // route:<site> sends that site's external links to the current Space; route: clears all.
            let site = String(command.dropFirst("route:".count))
            app.settings.linkRoutes = site.isEmpty ? [] : [LinkRoute(site: site, spaceID: browser.currentSpace.id)]
            print("[automation] routes \(app.settings.linkRoutes.map(\.site))")
        } else if command.hasPrefix("external:"), let url = URL(string: String(command.dropFirst("external:".count))) {
            app.openExternal(url)
            print("[automation] external opened; minis=\(app.miniWindows.count) space=\(app.activeWindow?.currentSpace.title ?? "-")")
        } else if command == "cleantest", let browser = app.activeWindow {
            // Removes this Space's tabs on the local test server (127.0.0.1 / localhost) only.
            let space = browser.currentSpace
            let local = { (tab: BrowserTab) -> Bool in ["127.0.0.1", "localhost"].contains((tab.url ?? tab.pinnedURL)?.host() ?? "") }
            for tab in (space.today + space.allPinnedTabs).filter(local) {
                app.contents.unload(tab)
                if case .pinned? = app.model.location(of: tab) { app.model.togglePin(tab) }
                app.model.discard(tab)
            }
            if let next = space.today.first ?? space.allPinnedTabs.first { browser.select(next) }
            print("[automation] cleaned; today=\(space.today.count) pinned=\(space.allPinnedTabs.count)")
        } else if command == "todayinfo", let browser = app.activeWindow {
            // For test Spaces: Today's tabs by path, with group/split markers.
            let rows = browser.currentSpace.today.map { tab in
                (tab.url?.lastPathComponent ?? "?") + (tab.groupID != nil ? "[g]" : "") + (tab.splitID != nil ? "[s]" : "")
            }
            let pinned = browser.currentSpace.allPinnedTabs.map { $0.url?.lastPathComponent ?? "?" }
            print("[automation] today: \(rows) pinned: \(pinned)")
        } else if command == "panelinfo" {
            let panels = NSApp.windows.filter { $0 is AutofillPanel && $0.isVisible }
            let popovers = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            print("[automation] autofill panels: \(panels.map { "\($0.frame) child=\($0.parent != nil)" }) popovers: \(popovers.map(\.frame))")
        } else if command.hasPrefix("js:"), let view = app.activeWindow?.selectedContent?.view as? WKWebView {
            // js:<code> runs in the selected page (page world) and prints the result.
            view.evaluateJavaScript(String(command.dropFirst(3))) { result, error in
                print("[automation] js -> \(result.map { "\($0)" } ?? "nil") \(error.map { "error: \($0)" } ?? "")")
            }
        } else if command == "purgespace", let browser = app.activeWindow, app.model.spaces.count > 1 {
            // Test cleanup: remove the current Space and its tabs without archiving them.
            let space = browser.currentSpace
            for tab in space.today { app.contents.unload(tab); app.model.discard(tab) }
            browser.switchToSpace(app.model.spaces[0])
            app.model.delete(space)
            print("[automation] purged space")
        } else if command.hasPrefix("scrolltest:"), let browser = app.activeWindow, let window = browser.window,
                  let view = browser.selectedContent?.view, let seconds = Double(command.dropFirst("scrolltest:".count)) {
            // Trackpad-style pixel scrolling into the page at 120 Hz: down for half the time, back up
            // for the other half, so the page ends where it started.
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let steps = Int(seconds * 120)
            for i in 0..<steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 120) {
                    MainActor.assumeIsolated {
                        let screen = window.convertPoint(toScreen: center)
                        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                               wheel1: i < steps / 2 ? -12 : 12, wheel2: 0, wheel3: 0) else { return }
                        cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
                        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                        if let event = NSEvent(cgEvent: cg) { view.scrollWheel(with: event) }
                    }
                }
            }
            print("[automation] \(command)")
        } else if command.hasPrefix("backdrop:"), let browser = app.activeWindow {
            // backdrop:off hides the window's glass/blur backdrop (for performance comparisons).
            browser.root.themeFrame.subviews.first?.isHidden = command.hasSuffix("off")
            print("[automation] \(command)")
        } else if command == "onboarding" {
            app.activeWindow?.showOnboarding(nil)
        } else if command == "reveal" {
            app.activeWindow?.setSidebarRevealed(true)
        } else if command.hasPrefix("drag:"), let window = frontWindow ?? window {
            // drag:x1,y1,x2,y2[,hold] in the front window's points from the top-left, one event per
            // frame; `hold` seconds before letting go.
            let v = command.dropFirst("drag:".count).split(separator: ",").compactMap { Double($0) }
            guard v.count >= 4 else { return }
            let hold = v.count > 4 ? v[4] : 0
            let steps = 12
            var events: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, NSPoint(x: v[0], y: v[1]))]
            for i in 1...steps {
                let f = Double(i) / Double(steps)
                events.append((.leftMouseDragged, NSPoint(x: v[0] + (v[2] - v[0]) * f, y: v[1] + (v[3] - v[1]) * f)))
            }
            events.append((.leftMouseUp, NSPoint(x: v[2], y: v[3])))
            func post(_ index: Int) {
                let (type, point) = events[index]
                let location = NSPoint(x: point.x, y: window.frame.height - point.y)
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: index,
                                                  clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    window.sendEvent(event)
                }
            }
            for index in events.indices {
                let delay = Double(index) * 0.016 + (index == events.count - 1 ? hold : 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { post(index) } }
            }
            print("[automation] \(command)")
        } else if command.hasPrefix("click:"), let window = frontWindow ?? window {
            // click:x,y[,count] in the front window's points from the top-left; delivered to Bezier only.
            let parts = command.dropFirst("click:".count).split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 2 else { return }
            let count = parts.count > 2 ? Int(parts[2]) : 1
            let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
            for n in 1...count {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      clickCount: n, pressure: type == .leftMouseDown ? 1 : 0) {
                        window.sendEvent(event)
                    }
                }
            }
            print("[automation] \(command)")
        } else if command.hasPrefix("action:") {
            let selector = Selector(String(command.dropFirst("action:".count)))
            // Explicit targets must implement the selector, or AppKit raises.
            let target = [app.activeWindow as NSObject?, NSApp.delegate as? NSObject]
                .compactMap { $0 }.first { $0.responds(to: selector) }
            let handled = target.map { NSApp.sendAction(selector, to: $0, from: nil) } ?? false
            print("[automation] \(command) handled=\(handled)")
        } else if command.hasPrefix("key:"), let window {
            let spec = command.dropFirst("key:".count).split(separator: "+").map(String.init)
            var flags: NSEvent.ModifierFlags = []
            for mod in spec.dropLast() {
                switch mod {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            let key = spec.last ?? ""
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: key,
                                               charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { return }
            let handled = window.performKeyEquivalent(with: event)
            print("[automation] \(command) handled=\(handled)")
        }
    }
}
#endif
