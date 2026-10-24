import AppKit
import BezierCore
import BezierEngine
import SwiftUI

/// One browser window. Owns per-window state and implements every browser action; the menu
/// bar, sidebar and Command Bar all call into here.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let app: AppContext
    let state: WindowState
    private(set) var root: BrowserRootView!
    private lazy var commandBar = CommandBarController(browser: self)
    private var appearanceObservation: NSKeyValueObservation?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var isTrackingMenu = false
    private var floatingHideWork: DispatchWorkItem?
    private var portraitPopover: NSPopover?
    private var onboarding: OnboardingController?
    private var paneClickMonitor: Any?

    var model: BrowserModel { app.model }
    /// Links from pinned tabs and Favorites preview on top of the page.
    private(set) var peek: PeekController!
    private var boostEditor: BoostEditorPresenter!

    init(app: AppContext, space: Space? = nil) {
        self.app = app
        let space = space ?? app.model.spaces[0]
        state = WindowState(space: space, systemIsDark: NSApp.effectiveAppearance.isDark)
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820))
        super.init(window: window)
        window.delegate = self

        root = BrowserRootView(state: state, sidebar: SidebarView(controller: self, model: app.model, state: state))
        window.contentView = root
        paneClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let point = event.locationInWindow
            let windowNumber = event.windowNumber
            MainActor.assumeIsolated {
                if let self, windowNumber == self.window?.windowNumber { self.focusPane(at: point) }
            }
            return event
        }
        let devBar = NSHostingView(rootView: DevToolbar(controller: self, state: state))
        devBar.safeAreaRegions = []
        devBar.sizingOptions = []
        root.card.toolbar = devBar
        peek = PeekController(browser: self)
        boostEditor = BoostEditorPresenter(browser: self)
        state.find.onSearch = { [weak self] backwards, restart in self?.runFind(backwards: backwards, restart: restart) }
        state.find.onClose = { [weak self] in self?.closeFind() }
        root.card.onSplitResized = { [weak self] fractions in
            guard let self, let splitID = self.selectedTab?.splitID else { return }
            self.model.resizeSplit(splitID, widths: fractions.map(Double.init), in: self.currentSpace)
        }
        root.onEdgeHover = { [weak self] in self?.setSidebarRevealed(true) }
        root.onFloatingExit = { [weak self] in self?.scheduleFloatingSidebarHide() }
        menuTrackingObservers = [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let began = note.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated {
                    self?.isTrackingMenu = began
                    if self?.isTrackingMenu == false { self?.scheduleFloatingSidebarHide() }
                }
            }
        }
        window.setFrameAutosaveName("BezierBrowserWindow")
        if !window.setFrameUsingName("BezierBrowserWindow") { window.center() }
        applyPalette(animated: false)

        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyPalette(animated: true) }
        }

        // Restore context: the space's last tab, or its first Today tab.
        if let first = space.today.first ?? space.allPinnedTabs.first { select(first) } else { showSelectedContent() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Selection

    var currentSpace: Space { model.space(state.spaceID) ?? model.spaces[0] }

    var selectedTab: BrowserTab? { state.selectedTabID.flatMap(model.tab(id:)) }

    var selectedContent: (any WebContent)? { selectedTab.flatMap(app.contents.existingContent(for:)) }

    func select(_ tab: BrowserTab) {
        if case .pinned(let spaceID)? = model.location(of: tab), spaceID != state.spaceID, let space = model.space(spaceID) {
            switchToSpace(space, selecting: tab)
            return
        }
        if case .today(let spaceID)? = model.location(of: tab), spaceID != state.spaceID, let space = model.space(spaceID) {
            switchToSpace(space, selecting: tab)
            return
        }
        state.selectedTabID = tab.id
        tab.lastActiveAt = .now
        showSelectedContent()
        model.didChange()
    }

    /// Shows the dev bar when the selected tab's site is in Developer Mode.
    func refreshDeveloperMode() {
        let on = isDeveloperMode(selectedTab) && !root.card.isSplit
        let height = on ? DevToolbar.height : 0
        guard root.card.toolbarHeight != height else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            root.card.toolbarHeight = height
            root.card.layoutSubtreeIfNeeded()
        }
    }

    func isDeveloperMode(_ tab: BrowserTab?) -> Bool {
        guard let tab else { return false }
        return app.settings.isDeveloperMode(tab.url ?? tab.pinnedURL)
    }

    private func showSelectedContent() {
        closeFind()
        peek.close()
        boostEditor.close()
        guard let tab = selectedTab else {
            root.card.show(nil)
            refreshDeveloperMode()
            window?.title = "Bezier"
            return
        }
        let profile = ProfileID(currentSpace.profile)
        if let splitID = tab.splitID, case .today? = model.location(of: tab) {
            let panes = currentSpace.panes(of: splitID)
            if panes.count > 1, let focused = panes.firstIndex(where: { $0 === tab }) {
                root.card.showSplit(panes.map { app.contents.content(for: $0, profile: profile).view }, focused: focused,
                                    widths: panes.map(\.splitWidth), stacked: tab.splitStacked)
                refreshDeveloperMode()
                window?.title = tab.displayTitle
                if window?.isKeyWindow == true, !commandBar.isVisible {
                    window?.makeFirstResponder(app.contents.existingContent(for: tab)?.view)
                }
                return
            }
        }
        let content = app.contents.content(for: tab, profile: profile)
        root.card.show(content.view)
        scheduleThumbnail(of: tab)
        refreshDeveloperMode()
        content.setVisible(true)
        window?.title = tab.displayTitle
        if tab.url == nil && tab.pinnedURL == nil { commandBar.show(mode: .newTab) }
        else if window?.isKeyWindow == true, !commandBar.isVisible { window?.makeFirstResponder(content.view) }
    }

    /// Tab Switcher pictures: the page a moment after it's shown (once it has drawn).
    private func scheduleThumbnail(of tab: BrowserTab) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.state.selectedTabID == tab.id else { return }
            self.app.contents.captureThumbnail(for: tab)
        }
    }

    func switchToSpace(_ space: Space, selecting tab: BrowserTab? = nil) {
        guard space.id != state.spaceID || tab != nil else { return }
        let from = model.spaces.firstIndex { $0.id == state.spaceID } ?? 0
        let to = model.spaces.firstIndex { $0.id == space.id } ?? 0
        state.spaceTransitionDirection = to >= from ? 1 : -1
        withAnimation(Motion.spring) {
            state.spaceID = space.id
        }
        applyPalette(animated: true)
        if let tab {
            select(tab)
        } else if state.selectedTabID == nil || state.selectedTabID.flatMap(model.tab(id:)) == nil {
            state.selectedTabID = (space.today.first ?? space.allPinnedTabs.first)?.id
            showSelectedContent()
        } else {
            showSelectedContent()
        }
    }

    private func applyPalette(animated: Bool) {
        let palette = ThemePalette(theme: currentSpace.theme, systemIsDark: NSApp.effectiveAppearance.isDark)
        state.palette = palette
        root.themeFrame.apply(palette, animated: animated)
        root.apply(palette)
    }

    // MARK: Called by the sidebar

    func toggle(_ folder: Folder) { model.toggle(folder) }

    func copy(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("Copied URL", symbol: "link")
    }

    func showToast(_ text: String, symbol: String) {
        state.toasts.show(text, symbol: symbol)
    }

    func move(_ tab: BrowserTab, to space: Space) {
        let wasSelected = tab.id == state.selectedTabID
        let neighbour = wasSelected ? nextTabAfterClosing(tab) : nil
        withAnimation(Motion.spring) { model.move(tab, to: space) }
        showToast("Moved to \(space.title)", symbol: "arrow.right.square")
        if wasSelected {
            state.selectedTabID = neighbour?.id
            showSelectedContent()
        }
    }

    /// The hover "×" / "−": archives Today tabs, unloads pinned tabs and favorites.
    func closeTab(_ tab: BrowserTab) {
        let wasSelected = tab.id == state.selectedTabID
        let neighbour = wasSelected ? nextTabAfterClosing(tab) : nil
        switch model.location(of: tab) {
        case .today?:
            app.contents.unload(tab)
            withAnimation(Motion.spring) { model.archive(tab) }
        case .pinned?, .favorite?:
            app.contents.unload(tab)
            if let pinned = tab.pinnedURL { tab.url = pinned }
        case nil:
            return
        }
        if wasSelected {
            state.selectedTabID = neighbour?.id
            if let neighbour { select(neighbour) } else { showSelectedContent() }
        }
    }

    private func nextTabAfterClosing(_ tab: BrowserTab) -> BrowserTab? {
        let tabs = currentSpace.visibleTabs.filter { $0 !== tab }
        let loaded = tabs.filter { app.contents.isLoaded($0) }
        return loaded.max { $0.lastActiveAt < $1.lastActiveAt } ?? currentSpace.today.first { $0 !== tab }
    }

    func closeGroup(_ id: UUID, in space: Space) {
        for tab in space.members(of: id) {
            if tab.id == state.selectedTabID { closeTab(tab) } else { app.contents.unload(tab) }
        }
        model.closeGroup(id, in: space)
    }

    // MARK: Drag to split / group

    /// A sidebar drop: edges split side by side, the middle groups.
    func handleSidebarDrop(_ draggedID: UUID, _ drop: SidebarDrop) {
        guard let dragged = model.tab(id: draggedID) else { return }
        let space = currentSpace
        let spring = Animation.spring(response: 0.38, dampingFraction: 0.78)
        switch drop {
        case .onto(let target, let zone) where zone == .above || zone == .below:
            let anchor = zone == .above ? target.leftTabID : target.rightTabID
            withAnimation(spring) { model.move(dragged, zone == .above ? .before : .after, anchor, in: space) }
            showSelectedContent()
        case .onto(let target, .into):
            withAnimation(spring) {
                if target.kind == .folder, let folder = Self.folder(target.leftTabID, in: space.pinned) {
                    model.move(dragged, into: folder, in: space)
                } else {
                    model.moveToTodayTop(dragged, in: space)
                }
            }
            showSelectedContent()
        case .onto(let target, let zone) where zone == .left || zone == .right:
            guard let anchor = model.tab(id: zone == .left ? target.leftTabID : target.rightTabID) else { return }
            withAnimation(spring) { model.split(dragged, onto: anchor, side: zone == .left ? .left : .right, in: space) }
            select(dragged)
        case .onto(let target, _):
            guard let anchor = model.tab(id: target.leftTabID) else { return }
            withAnimation(spring) { model.group(dragged, onto: anchor, in: space) }
            showSelectedContent()
        case .outOfGroup(let below):
            withAnimation(spring) { model.removeFromGroup(dragged, below: below, in: space) }
            showSelectedContent()
        }
    }

    private static func folder(_ id: UUID, in nodes: [SidebarNode]) -> Folder? {
        for case .folder(let candidate) in nodes {
            if candidate.id == id { return candidate }
            if let found = folder(id, in: candidate.children) { return found }
        }
        return nil
    }

    /// Moves a Space to another profile. Its loaded pages reload in the new profile's data
    /// store (cookies, storage) the next time they're shown.
    func setProfile(_ profile: String, for space: Space) {
        guard profile != space.profile else { return }
        model.setProfile(profile, for: space)
        for tab in space.allPinnedTabs + space.today { app.contents.unload(tab) }
        if space === currentSpace { showSelectedContent() }
        showToast("\(space.title) now uses the \(Self.profileName(profile)) profile", symbol: "person.crop.circle")
    }

    static func profileName(_ profile: String) -> String { profile == "default" ? "Default" : profile }

    /// Asks for a name, then moves the Space to that new profile.
    func newProfile(for space: Space) {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "A profile keeps its own cookies and site data, so you can be signed in to different accounts in different Spaces."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                guard response == .alertFirstButtonReturn, !name.isEmpty, name.lowercased() != "default" else { return }
                self?.setProfile(name, for: space)
            }
        }
    }

    /// Side by side ⇄ top to bottom.
    func toggleSplitArrangement(_ splitID: UUID) {
        let stacked = currentSpace.panes(of: splitID).first?.splitStacked ?? false
        model.setSplitStacked(splitID, !stacked, in: currentSpace)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = Motion.expoOut
            context.allowsImplicitAnimation = true
            showSelectedContent()
            root.card.layoutSubtreeIfNeeded()
        }
    }

    func separateSplit(_ splitID: UUID) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { model.unsplit(splitID, in: currentSpace) }
        showSelectedContent()
    }

    /// Clicking into a pane focuses its tab without rebuilding the split.
    private func focusPane(at point: NSPoint) {
        guard root.card.isSplit, let index = root.card.paneIndex(atWindowPoint: point),
              let tab = selectedTab, let splitID = tab.splitID else { return }
        let panes = currentSpace.panes(of: splitID)
        guard panes.indices.contains(index), panes[index].id != state.selectedTabID else { return }
        state.selectedTabID = panes[index].id
        panes[index].lastActiveAt = .now
        root.card.setFocusedPane(index)
        window?.title = panes[index].displayTitle
    }

    /// Drops a tab that only existed to start a download, returning to the previous tab.
    func discard(_ tab: BrowserTab) {
        guard case .today? = model.location(of: tab) else { return }
        let wasSelected = tab.id == state.selectedTabID
        let neighbour = wasSelected ? nextTabAfterClosing(tab) : nil
        app.contents.unload(tab)
        withAnimation(Motion.spring) { model.discard(tab) }
        if wasSelected {
            state.selectedTabID = neighbour?.id
            if let neighbour { select(neighbour) } else { showSelectedContent() }
        }
    }

    func togglePin(_ tab: BrowserTab) { withAnimation(Motion.spring) { model.togglePin(tab) } }
    func addToFavorites(_ tab: BrowserTab) { withAnimation(Motion.spring) { model.addToFavorites(tab) } }
    func removeFromFavorites(_ tab: BrowserTab) { withAnimation(Motion.spring) { model.removeFromFavorites(tab, to: currentSpace) } }

    func duplicate(_ tab: BrowserTab) {
        let copy = model.duplicate(tab, in: currentSpace)
        select(copy)
    }

    func resetToPinnedURL(_ tab: BrowserTab) {
        guard let url = tab.pinnedURL else { return }
        tab.url = url
        app.contents.existingContent(for: tab)?.load(url)
        model.didChange()
    }

    func beginRename(_ tab: BrowserTab) { state.renamingTabID = tab.id }

    func finishRename(_ tab: BrowserTab, title: String?) {
        if let title { model.rename(tab, to: title == tab.title ? nil : title) }
        state.renamingTabID = nil
    }

    func setTheme(_ theme: SpaceTheme, for space: Space, animated: Bool = true) {
        space.theme = theme
        model.didChange()
        if space.id == state.spaceID { applyPalette(animated: animated) }
    }

    // MARK: Space editing (theme, icon, name)

    /// Shows the theme or icon popover on the Space header, revealing the sidebar if needed.
    func editSpace(_ space: Space, panel: SpaceEditorPanel) {
        prepareHeaderEditing(for: space)
        DispatchQueue.main.async { self.state.spaceEditor = SpaceEditor(spaceID: space.id, panel: panel) }
    }

    func beginRenameSpace(_ space: Space) {
        prepareHeaderEditing(for: space)
        state.renamingSpaceID = space.id
    }

    func finishRenameSpace(_ space: Space, title: String?) {
        if let title { model.rename(space, to: title) }
        state.renamingSpaceID = nil
    }

    private func prepareHeaderEditing(for space: Space) {
        if space.id != state.spaceID { switchToSpace(space) }
        if state.isLibraryOpen { closeLibrary() }
        if !state.sidebarVisible { setSidebarRevealed(true) }
    }

    func confirmDelete(_ space: Space) {
        guard model.spaces.count > 1, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(space.title)”?"
        alert.informativeText = "Its pinned tabs and folders are removed. Its Today tabs move to the Archive."
        alert.addButton(withTitle: "Delete Space").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self.delete(space) }
        }
    }

    private func delete(_ space: Space) {
        let index = model.spaces.firstIndex { $0 === space } ?? 0
        let wasCurrent = space.id == state.spaceID
        for tab in space.allPinnedTabs + space.today { app.contents.unload(tab) }
        guard model.delete(space) else { return }
        NSSound(named: "Funk")?.play()
        if wasCurrent { switchToSpace(model.spaces[max(0, index - 1)]) }
        showToast("Deleted \(space.title)", symbol: "trash")
    }

    // MARK: Library

    @objc func toggleLibrary(_ sender: Any?) {
        state.isLibraryOpen ? closeLibrary() : openLibrary(state.librarySection)
    }

    func openLibrary(_ section: LibrarySection) {
        if !state.sidebarVisible { setSidebarRevealed(true) }
        animateSidebar {
            withAnimation(Motion.spring) {
                state.librarySection = section
                state.isLibraryOpen = true
            }
        }
    }

    func closeLibrary() {
        guard state.isLibraryOpen else { return }
        animateSidebar { withAnimation(Motion.spring) { state.isLibraryOpen = false } }
    }

    @objc func showDownloads(_ sender: Any?) { openLibrary(.downloads) }
    @objc func showHistory(_ sender: Any?) { openLibrary(.history) }
    @objc func showSpacesLibrary(_ sender: Any?) { openLibrary(.spaces) }

    func restoreArchived(_ item: ArchivedTab) {
        let tab = withAnimation(Motion.spring) { model.restore(item, into: currentSpace) }
        select(tab)
    }

    func clearArchive() {
        model.archive.removeAll()
        model.didChange()
        showToast("Archive cleared", symbol: "archivebox")
    }

    func confirmClearHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all browsing history?"
        alert.informativeText = "This removes every page from History and Command Bar suggestions. Open tabs stay open."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self.app.history.clear()
                self.showToast("History cleared", symbol: "clock.arrow.circlepath")
            }
        }
    }

    // Spaces menu (act on the current Space)
    @objc func editThemeOfCurrentSpace(_ sender: Any?) { editSpace(currentSpace, panel: .theme) }
    @objc func changeIconOfCurrentSpace(_ sender: Any?) { editSpace(currentSpace, panel: .icon) }
    @objc func renameCurrentSpace(_ sender: Any?) { beginRenameSpace(currentSpace) }
    @objc func deleteCurrentSpace(_ sender: Any?) { confirmDelete(currentSpace) }

    func navigateSelected(to url: URL) {
        guard let tab = selectedTab else { return openInNewTab(url) }
        let content = app.contents.content(for: tab, profile: ProfileID(currentSpace.profile))
        content.load(url)
        tab.url = url
        model.didChange()
    }

    func openInNewTab(_ url: URL, background: Bool = false) {
        let tab = withAnimation(Motion.spring) { model.newTab(url: url, in: currentSpace) }
        if background { _ = app.contents.content(for: tab, profile: ProfileID(currentSpace.profile)) } else { select(tab) }
    }

    /// A page opened a tab (target=_blank, window.open, ⌘-click).
    func handleOpenedTab(opener: BrowserTab, newTab: BrowserTab, disposition: OpenDisposition) {
        if disposition != .backgroundTab { select(newTab) }
    }

    // MARK: Menu actions (responder chain)

    @objc func newTab(_ sender: Any?) { commandBar.show(mode: .newTab) }

    #if DEBUG
    func debugShowCommandBar(query: String) {
        commandBar.show(mode: .newTab)
        commandBar.setQuery(query)
    }

    func debugCommandBar(_ key: String) -> String { commandBar.debug(key) }
    func debugSetCommandBarQuery(_ text: String) { commandBar.setQuery(text) }
    #endif
    @objc func openLocation(_ sender: Any?) { commandBar.show(mode: selectedTab == nil ? .newTab : .editCurrent) }

    @objc func archiveTab(_ sender: Any?) {
        if commandBar.isVisible { commandBar.hide(); return }
        if let tab = selectedTab { closeTab(tab) } else { window?.performClose(nil) }
    }

    @objc func restoreLastClosedTab(_ sender: Any?) {
        guard let tab = model.restoreLastArchived(fallback: currentSpace) else { return }
        select(tab)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        let visible = !state.sidebarVisible
        animateSidebar {
            state.sidebarVisible = visible
            state.sidebarRevealed = false
        }
    }

    /// Hidden sidebar slides out over the page when the pointer reaches the left edge.
    func setSidebarRevealed(_ revealed: Bool) {
        floatingHideWork?.cancel()
        guard !state.sidebarVisible, state.sidebarRevealed != revealed else { return }
        animateSidebar(duration: revealed ? 0.28 : 0.22) { state.sidebarRevealed = revealed }
    }

    /// Hides the floating sidebar shortly after the pointer leaves it, unless a menu,
    /// the Command Bar or an inline rename is using it.
    func scheduleFloatingSidebarHide() {
        floatingHideWork?.cancel()
        guard state.sidebarRevealed else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isTrackingMenu, !self.commandBar.isVisible, self.state.renamingTabID == nil,
                      self.state.renamingSpaceID == nil, self.state.spaceEditor == nil, !self.state.isLibraryOpen,
                      let window = self.window else { return }
                let pointer = self.root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.root.sidebarFrame.insetBy(dx: -14, dy: -14).contains(pointer) { return }
                self.setSidebarRevealed(false)
            }
        }
        floatingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func animateSidebar(duration: TimeInterval = Motion.sidebarToggle, _ change: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = Motion.expoOut
            context.allowsImplicitAnimation = true
            change()
            (window as? BrowserWindow)?.trafficLightsVisible = state.sidebarVisible || state.sidebarRevealed
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
    }

    @objc func reloadPage(_ sender: Any?) { selectedContent?.reload(ignoringCache: false) }
    @objc func forceReloadPage(_ sender: Any?) { selectedContent?.reload(ignoringCache: true) }
    @objc func stopLoading(_ sender: Any?) { selectedContent?.stopLoading() }
    @objc func goBack(_ sender: Any?) { selectedContent?.goBack() }
    @objc func goForward(_ sender: Any?) { selectedContent?.goForward() }
    @objc func copyURL(_ sender: Any?) { copy(selectedTab?.url) }

    @objc func copyURLAsMarkdown(_ sender: Any?) {
        guard let tab = selectedTab, let url = tab.url else { return }
        let title = tab.displayTitle.replacingOccurrences(of: "]", with: "\\]")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(title)](\(url.absoluteString))", forType: .string)
        showToast("Copied as Markdown", symbol: "link")
    }

    // Developer (View › Developer in Arc)
    @objc func showDevTools(_ sender: Any?) { selectedContent?.perform(.showDevTools) }
    @objc func showNetwork(_ sender: Any?) { selectedContent?.perform(.showNetwork) }

    /// ⌃D. Per site; on by default for localhost and 127.x.
    @objc func toggleDeveloperMode(_ sender: Any?) {
        guard let url = selectedTab?.url else { return }
        app.settings.toggleDeveloperMode(for: url)
        refreshDeveloperMode()
        let on = app.settings.isDeveloperMode(url)
        showToast(on ? "Developer Mode on for \(DeveloperMode.siteKey(url) ?? "")" : "Developer Mode off", symbol: "chevron.left.forwardslash.chevron.right")
    }

    // MARK: Onboarding

    @objc func showOnboarding(_ sender: Any?) {
        guard onboarding == nil else { return }
        let controller = OnboardingController(browser: self)
        onboarding = controller
        controller.start()
    }

    func onboardingFinished() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.onboarding = nil }
    }

    // MARK: Capture

    /// ⇧⌘2. The visible page, copied and saved to Downloads (shows up in the Library).
    private var captureOverlay: CaptureOverlayView?

    /// ⇧⌘2: drag over the page for an area, or capture the visible page or all of it.
    @objc func capturePage(_ sender: Any?) {
        guard let content = selectedContent, captureOverlay == nil else { return }
        let overlay = CaptureOverlayView()
        overlay.onChoice = { [weak self, weak overlay] choice in
            guard let self, let overlay else { return }
            let pageRect: CGRect? = if case .area(let rect) = choice { content.view.convert(rect, from: overlay) } else { nil }
            overlay.removeFromSuperview()
            self.captureOverlay = nil
            self.window?.makeFirstResponder(content.view)
            Task {
                let image: NSImage? = switch choice {
                case .area: await content.snapshot(of: pageRect ?? .zero)
                case .visible: await content.snapshot()
                case .fullPage: await content.fullPageSnapshot()
                case .cancel: nil
                }
                if let image { self.saveCapture(image, name: "Capture", toast: "Capture copied") }
            }
        }
        root.showOverlay(overlay)
        overlay.animateIn()
        window?.makeFirstResponder(overlay)
        captureOverlay = overlay
    }

    /// Opens the Portrait Mode popover: from the dev bar when it's showing, otherwise anchored to
    /// the top-right of the page card.
    @objc func captureInPortraitMode(_ sender: Any?) {
        guard selectedContent != nil else { return }
        if root.card.toolbarHeight > 0 {
            state.portraitCaptureOpen = true
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PortraitCaptureView(controller: self))
        let anchor = NSRect(x: root.card.bounds.maxX - 150, y: root.card.bounds.maxY - 6, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: root.card, preferredEdge: .minY)
        portraitPopover = popover
    }

    func savePortrait(_ image: NSImage) {
        state.portraitCaptureOpen = false
        portraitPopover?.close()
        saveCapture(image, name: "Portrait", toast: "Portrait capture copied")
    }

    private func saveCapture(_ image: NSImage, name: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        let stamp = Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let host = URLInput.displayHost(selectedTab?.url)
        let filename = "Bezier \(name) \(host.isEmpty ? "" : host + " ")\(stamp).png"
        let destination = app.engine.downloadDirectory.appending(path: filename)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           (try? png.write(to: destination)) != nil {
            let item = DownloadItem(sourceURL: selectedTab?.url, filename: filename, fileURL: destination, state: .completed,
                                    receivedBytes: Int64(png.count), totalBytes: Int64(png.count))
            app.downloads.store.add(item)
        }
        showToast(toast, symbol: "camera.viewfinder")
    }
    @objc func showConsole(_ sender: Any?) { selectedContent?.perform(.showConsole) }
    @objc func inspectElement(_ sender: Any?) { selectedContent?.perform(.inspectElement) }

    @objc func viewSource(_ sender: Any?) {
        guard let url = selectedTab?.url?.viewSourceURL else { return }
        openInNewTab(url)
    }

    @objc func clearCookiesAndRefresh(_ sender: Any?) {
        selectedContent?.perform(.clearCookiesAndReload)
        showToast("Cleared cookies for \(URLInput.displayHost(selectedTab?.url))", symbol: "trash")
    }

    @objc func clearCacheAndRefresh(_ sender: Any?) {
        selectedContent?.perform(.clearCacheAndReload)
        showToast("Cleared cache for \(URLInput.displayHost(selectedTab?.url))", symbol: "trash")
    }

    @objc func collapseAllFolders(_ sender: Any?) { withAnimation(Motion.snappy) { model.setFoldersExpanded(false, in: currentSpace) } }
    @objc func expandAllFolders(_ sender: Any?) { withAnimation(Motion.snappy) { model.setFoldersExpanded(true, in: currentSpace) } }

    @objc func togglePinSelected(_ sender: Any?) { if let tab = selectedTab { togglePin(tab) } }
    @objc func addSelectedToFavorites(_ sender: Any?) { if let tab = selectedTab { addToFavorites(tab) } }
    @objc func duplicateSelected(_ sender: Any?) { if let tab = selectedTab { duplicate(tab) } }
    @objc func renameSelected(_ sender: Any?) { if let tab = selectedTab { beginRename(tab) } }

    @objc func clearToday(_ sender: Any?) {
        for tab in currentSpace.today where tab.id != state.selectedTabID { app.contents.unload(tab) }
        withAnimation(Motion.spring) { model.clearToday(in: currentSpace, keeping: selectedTab) }
    }

    @objc func nextSpace(_ sender: Any?) { cycleSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { cycleSpace(by: -1) }

    /// ⌃1…⌃9, tag = index.
    @objc func selectSpaceAtIndex(_ sender: NSMenuItem) {
        guard model.spaces.indices.contains(sender.tag) else { return }
        switchToSpace(model.spaces[sender.tag])
    }

    private func cycleSpace(by delta: Int) {
        guard let i = model.spaces.firstIndex(where: { $0.id == state.spaceID }) else { return }
        let j = i + delta
        guard model.spaces.indices.contains(j) else { return }
        switchToSpace(model.spaces[j])
    }

    @objc func nextTab(_ sender: Any?) { cycleTab(by: 1) }
    @objc func previousTab(_ sender: Any?) { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        let tabs = model.favorites + currentSpace.visibleTabs
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == state.selectedTabID } ?? -delta
        select(tabs[(i + delta + tabs.count) % tabs.count])
    }

    /// ⌘1…⌘9: favorites first, then pinned tabs; ⌘9 is always the last tab.
    @objc func selectTabAtIndex(_ sender: NSMenuItem) {
        let tabs = model.favorites + currentSpace.allPinnedTabs
        if sender.tag == 8 {
            if let last = (model.favorites + currentSpace.visibleTabs).last { select(last) }
        } else if tabs.indices.contains(sender.tag) {
            select(tabs[sender.tag])
        }
    }

    @objc func newSpace(_ sender: Any?) {
        let theme = SpaceTheme.newSpaceDefault(index: model.spaces.count)
        let space = model.newSpace(title: "Space \(model.spaces.count + 1)", theme: theme)
        switchToSpace(space)
    }

    @objc func newFolder(_ sender: Any?) {
        withAnimation(Motion.spring) { _ = model.newFolder(in: currentSpace) }
    }

    @objc func showArchive(_ sender: Any?) { openLibrary(.archive) }

    @objc func zoomIn(_ sender: Any?) { if let c = selectedContent { c.pageZoom = min(3, c.pageZoom + 0.1) } }
    @objc func zoomOut(_ sender: Any?) { if let c = selectedContent { c.pageZoom = max(0.3, c.pageZoom - 0.1) } }
    @objc func zoomReset(_ sender: Any?) {
        selectedContent?.pageZoom = 1
        selectedContent?.setMagnification(1, centeredAt: .zero)
    }

    // MARK: Swiping between Spaces

    /// Horizontal travel of a two-finger swipe over the sidebar; nil when not swiping.
    private var spaceSwipe: CGFloat?
    private var swallowMomentum = false

    /// Trackpad swipes over the sidebar: the Space follows the fingers and, past a threshold,
    /// gives way to the next one. Returns true when the event was used.
    func handleSidebarScroll(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.momentumPhase != [] { return swallowMomentum }
        let dx = event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
        switch event.phase {
        case .began, .mayBegin:
            spaceSwipe = nil
            swallowMomentum = false
            return false
        case .changed:
            if spaceSwipe == nil {
                // Only a clearly sideways gesture becomes a swipe; vertical scrolling stays scrolling.
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5, abs(event.scrollingDeltaX) > 0.5 else { return false }
                spaceSwipe = 0
            }
            spaceSwipe! += dx
            let index = model.spaces.firstIndex { $0.id == state.spaceID } ?? 0
            let hasNeighbour = spaceSwipe! < 0 ? index + 1 < model.spaces.count : index > 0
            // Rubber band: easy toward a neighbour, stiff where there's none.
            let travel = spaceSwipe!
            state.spaceSwipeOffset = hasNeighbour ? travel * 0.6 : travel / (1 + abs(travel) / 40) * 0.5
            return true
        case .ended, .cancelled:
            guard let travel = spaceSwipe else { return false }
            spaceSwipe = nil
            swallowMomentum = true
            let index = model.spaces.firstIndex { $0.id == state.spaceID } ?? 0
            let target = travel < -70 ? index + 1 : (travel > 70 ? index - 1 : index)
            if target != index, model.spaces.indices.contains(target), event.phase == .ended {
                // The outgoing Space carries on from where the fingers left it.
                withAnimation(Motion.spring) { state.spaceSwipeOffset = 0 }
                switchToSpace(model.spaces[target])
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { state.spaceSwipeOffset = 0 }
            }
            return true
        default:
            return spaceSwipe != nil
        }
    }

    // MARK: Tab Switcher

    private var switcherTabs: [BrowserTab]?
    private var switcherReveal: Task<Void, Never>?
    var isTabSwitcherActive: Bool { switcherTabs != nil }

    /// ⌃Tab / ⌃⇧Tab while Control is held. Recent tabs first; the current tab is the first card.
    func advanceTabSwitcher(backwards: Bool) {
        let switcher = state.switcher
        if switcherTabs == nil {
            var seen = Set<UUID>()
            let tabs = (model.favorites + currentSpace.allPinnedTabs + currentSpace.today)
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
                .prefix(10)
            guard tabs.count > 1 else { return }
            if let current = selectedTab { app.contents.captureThumbnail(for: current) }
            switcherTabs = Array(tabs)
            switcher.selected = 0
            switcher.onPick = { [weak self] index in
                self?.state.switcher.selected = index
                self?.commitTabSwitcher()
            }
            // Only show the cards if Control is still held a moment later.
            switcherReveal = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, !Task.isCancelled, let tabs = self.switcherTabs else { return }
                self.state.switcher.items = tabs.map { tab in
                    TabSwitcherModel.Item(id: tab.id, title: tab.displayTitle, pageURL: tab.url ?? tab.pinnedURL,
                                          faviconURL: tab.faviconURL, thumbnail: self.app.contents.thumbnails[tab.id])
                }
                self.root.setSwitcherVisible(true)
            }
        }
        guard let count = switcherTabs?.count else { return }
        switcher.selected = (switcher.selected + (backwards ? -1 : 1) + count) % count
    }

    func commitTabSwitcher() {
        guard let tabs = switcherTabs else { return }
        let index = state.switcher.selected
        endTabSwitcher()
        if tabs.indices.contains(index) { select(tabs[index]) }
    }

    func endTabSwitcher() {
        guard switcherTabs != nil else { return }
        switcherReveal?.cancel()
        switcherTabs = nil
        root.setSwitcherVisible(false)
    }

    // MARK: Boosts

    @objc func boostThisSite(_ sender: Any?) {
        if boostEditor.isShowing { boostEditor.close() } else { boostEditor.show() }
    }

    // MARK: Find on page

    private var findTask: Task<Void, Never>?

    @objc func showFind(_ sender: Any?) {
        guard selectedContent != nil else { return }
        let find = state.find
        if !find.isVisible {
            find.isVisible = true
            root.setFindVisible(true)
            if !find.query.isEmpty { runFind(backwards: false, restart: true) }
        }
        find.focusRequest += 1
    }

    @objc func findNext(_ sender: Any?) {
        if state.find.query.isEmpty || !state.find.isVisible { showFind(nil) }
        runFind(backwards: false, restart: !state.find.hasSearched)
    }

    @objc func findPrevious(_ sender: Any?) {
        if state.find.query.isEmpty || !state.find.isVisible { showFind(nil) }
        runFind(backwards: true, restart: false)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard let content = selectedContent else { return }
        Task {
            guard let text = await content.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            state.find.query = String(text.prefix(200).split(whereSeparator: \.isNewline).first ?? "")
            showFind(nil)
        }
    }

    func closeFind() {
        guard state.find.isVisible else { return }
        state.find.isVisible = false
        findTask?.cancel()
        root.setFindVisible(false)
        if window?.isKeyWindow == true, let view = selectedContent?.view { window?.makeFirstResponder(view) }
    }

    private func runFind(backwards: Bool, restart: Bool) {
        let find = state.find
        let query = find.query
        findTask?.cancel()
        guard let content = selectedContent, !query.isEmpty else {
            find.total = 0
            find.current = 0
            find.hasSearched = false
            return
        }
        findTask = Task {
            let result = await content.find(query, backwards: backwards, restart: restart)
            guard !Task.isCancelled, query == find.query else { return }
            find.hasSearched = true
            find.total = result.found ? max(result.matches, 1) : 0
            if find.total == 0 {
                find.current = 0
            } else if restart || find.current == 0 {
                find.current = backwards ? find.total : 1
            } else {
                find.current = backwards ? (find.current + find.total - 2) % find.total + 1 : find.current % find.total + 1
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showFind(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(useSelectionForFind(_:)):
            selectedContent != nil
        case #selector(boostThisSite(_:)):
            {
                item.title = app.boosts.store.boost(for: selectedTab?.url) == nil ? "Boost This Site…" : "Edit Boost…"
                return Boost.domain(for: selectedTab?.url) != nil
            }()
        case #selector(goBack(_:)): selectedContent?.state.canGoBack ?? false
        case #selector(goForward(_:)): selectedContent?.state.canGoForward ?? false
        case #selector(reloadPage(_:)), #selector(forceReloadPage(_:)), #selector(stopLoading(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomReset(_:)):
            selectedContent != nil
        case #selector(showDevTools(_:)): selectedContent?.supports(.showDevTools) ?? false
        case #selector(showNetwork(_:)): selectedContent?.supports(.showNetwork) ?? false
        case #selector(capturePage(_:)), #selector(captureInPortraitMode(_:)): selectedContent != nil
        case #selector(toggleDeveloperMode(_:)):
            {
                item.state = isDeveloperMode(selectedTab) ? .on : .off
                return DeveloperMode.siteKey(selectedTab?.url) != nil
            }()
        case #selector(showConsole(_:)): selectedContent?.supports(.showConsole) ?? false
        case #selector(inspectElement(_:)): selectedContent?.supports(.inspectElement) ?? false
        case #selector(clearCookiesAndRefresh(_:)): selectedContent?.supports(.clearCookiesAndReload) ?? false
        case #selector(clearCacheAndRefresh(_:)): selectedContent?.supports(.clearCacheAndReload) ?? false
        case #selector(viewSource(_:)): selectedTab?.url?.scheme?.hasPrefix("http") ?? false
        case #selector(copyURL(_:)), #selector(copyURLAsMarkdown(_:)), #selector(togglePinSelected(_:)), #selector(duplicateSelected(_:)),
             #selector(addSelectedToFavorites(_:)), #selector(renameSelected(_:)):
            selectedTab != nil
        case #selector(toggleSidebar(_:)):
            { item.title = state.sidebarVisible ? "Hide Sidebar" : "Show Sidebar"; return true }()
        case #selector(restoreLastClosedTab(_:)): !model.archive.isEmpty
        case #selector(deleteCurrentSpace(_:)): model.spaces.count > 1
        case #selector(toggleLibrary(_:)):
            { item.title = state.isLibraryOpen ? "Hide Library" : "View Library"; return true }()
        default: true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        app.activeWindow = self
        // A tab can only live in one window; re-attach ours when we come forward.
        showSelectedContent()
    }

    func windowDidBecomeMain(_ notification: Notification) { root.card.setKey(true) }
    func windowDidResignMain(_ notification: Notification) { root.card.setKey(false) }

    func windowDidResize(_ notification: Notification) { (window as? BrowserWindow)?.layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { (window as? BrowserWindow)?.layoutTrafficLights() }

    func windowWillClose(_ notification: Notification) {
        app.windowClosed(self)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
