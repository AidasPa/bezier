import Foundation
import Observation

/// Where a tab sits in the sidebar.
public enum TabLocation: Equatable, Sendable {
    case favorite
    case pinned(spaceID: UUID)
    case today(spaceID: UUID)
}

/// The shared sidebar state of the whole browser (Arc shares the sidebar across windows).
/// Every mutation goes through a method here so persistence stays in one place.
@MainActor
@Observable
public final class BrowserModel {
    public var spaces: [Space]
    public var favorites: [BrowserTab]
    public var archive: [ArchivedTab]
    /// Seconds of inactivity before a Today tab is archived; 0 means never.
    public var autoArchiveAfter: TimeInterval = 12 * 60 * 60

    /// Called after every mutation; the store debounces writes.
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(spaces: [Space], favorites: [BrowserTab] = [], archive: [ArchivedTab] = []) {
        precondition(!spaces.isEmpty, "a browser always has at least one space")
        self.spaces = spaces
        self.favorites = favorites
        self.archive = archive
    }

    public func didChange() { onChange?() }

    // MARK: Lookup

    public func space(_ id: UUID?) -> Space? { spaces.first { $0.id == id } }

    public func location(of tab: BrowserTab) -> TabLocation? {
        if favorites.contains(where: { $0 === tab }) { return .favorite }
        for space in spaces {
            if space.today.contains(where: { $0 === tab }) { return .today(spaceID: space.id) }
            if space.allPinnedTabs.contains(where: { $0 === tab }) { return .pinned(spaceID: space.id) }
        }
        return nil
    }

    public func tab(id: UUID) -> BrowserTab? {
        if let tab = favorites.first(where: { $0.id == id }) { return tab }
        for space in spaces {
            if let tab = space.today.first(where: { $0.id == id }) ?? space.allPinnedTabs.first(where: { $0.id == id }) {
                return tab
            }
        }
        return nil
    }

    // MARK: Tabs

    /// New tabs go to the top of Today, like Arc.
    @discardableResult
    public func newTab(url: URL?, in space: Space, title: String? = nil) -> BrowserTab {
        let tab = BrowserTab(url: url, title: title)
        space.today.insert(tab, at: 0)
        didChange()
        return tab
    }

    /// Inserts a tab right below `anchor` in Today (used for tabs a page opens).
    @discardableResult
    public func insertTab(url: URL?, in space: Space, after anchor: BrowserTab?) -> BrowserTab {
        let tab = BrowserTab(url: url)
        if let anchor, let i = space.today.firstIndex(where: { $0 === anchor }) {
            space.today.insert(tab, at: i + 1)
        } else {
            space.today.insert(tab, at: 0)
        }
        didChange()
        return tab
    }

    // MARK: Split View & drag-to-group

    public enum DropSide: Sendable { case left, right }

    /// Drag `dragged` onto `target`'s left/right edge: they become (or join) a Split View,
    /// shown as one sidebar row. Up to 4 panes.
    public func split(_ dragged: BrowserTab, onto target: BrowserTab, side: DropSide, in space: Space) {
        guard dragged !== target, space.today.contains(where: { $0 === target }) else { return }
        let splitID = target.splitID ?? UUID()
        if target.splitID != splitID { target.splitID = splitID }
        guard dragged.splitID == splitID || space.panes(of: splitID).count < 4 else { return }
        detach(dragged, keepingIn: space)
        dragged.splitID = splitID
        dragged.groupID = target.groupID
        let index = space.today.firstIndex { $0 === target } ?? 0
        space.today.insert(dragged, at: side == .left ? index : index + 1)
        for tab in space.panes(of: splitID) { tab.splitWidth = nil }     // a new pane: back to equal widths
        dragged.splitStacked = target.splitStacked
        normalizeGroups(in: space)
        normalizeSplits(in: space)
        didChange()
    }

    /// Side by side, or top to bottom.
    public func setSplitStacked(_ splitID: UUID, _ stacked: Bool, in space: Space) {
        for tab in space.panes(of: splitID) { tab.splitStacked = stacked }
        didChange()
    }

    /// Dragging a Split View divider: each pane's share of the width, left to right.
    public func resizeSplit(_ splitID: UUID, widths: [Double], in space: Space) {
        let panes = space.panes(of: splitID)
        guard panes.count == widths.count else { return }
        for (tab, width) in zip(panes, widths) { tab.splitWidth = width }
        didChange()
    }

    /// Drag `dragged` onto the middle of `target`: they form (or join) a group.
    public func group(_ dragged: BrowserTab, onto target: BrowserTab, in space: Space) {
        guard dragged !== target, space.today.contains(where: { $0 === target }) else { return }
        detach(dragged, keepingIn: space)
        let groupID: UUID
        if let existing = target.groupID, space.group(existing) != nil {
            groupID = existing
        } else {
            let title = (target.url ?? target.pinnedURL).map(URLInput.displayHost) ?? target.displayTitle
            let group = TabGroup(title: title.isEmpty ? target.displayTitle : title)
            space.groups.append(group)
            groupID = group.id
            for tab in space.today where tab === target || (target.splitID != nil && tab.splitID == target.splitID) {
                tab.groupID = groupID
            }
        }
        dragged.groupID = groupID
        dragged.splitID = nil
        let last = space.today.lastIndex { $0.groupID == groupID } ?? (space.today.firstIndex { $0 === target } ?? 0)
        space.today.insert(dragged, at: min(last + 1, space.today.count))
        if let i = space.groups.firstIndex(where: { $0.id == groupID }) { space.groups[i].isCollapsed = false }
        normalizeGroups(in: space)
        normalizeSplits(in: space)
        didChange()
    }

    /// "Separate Tabs": the panes become ordinary tabs again, in place.
    public func unsplit(_ splitID: UUID, in space: Space) {
        for tab in space.today where tab.splitID == splitID { tab.splitID = nil; tab.splitWidth = nil }
        didChange()
    }

    /// A split of one is just a tab; a split that lost a pane goes back to equal widths.
    public func normalizeSplits(in space: Space) {
        let ids = Set(space.today.compactMap(\.splitID))
        for id in ids {
            let panes = space.panes(of: id)
            if panes.count < 2 {
                for tab in panes { tab.splitID = nil; tab.splitWidth = nil }
            } else if panes.contains(where: { $0.splitWidth == nil }) {
                for tab in panes { tab.splitWidth = nil }
            }
        }
    }

    /// Takes a Today tab out of its list (and pinned tabs out of the pinned tree) so it can be
    /// re-inserted elsewhere in Today.
    private func detach(_ tab: BrowserTab, keepingIn space: Space) {
        for s in spaces {
            if s.today.contains(where: { $0 === tab }) { s.today.removeAll { $0 === tab } }
            removePinned(tab, from: s)
            if s !== space { normalizeGroups(in: s); normalizeSplits(in: s) }
        }
        tab.pinnedURL = nil
        tab.splitID = nil
        tab.splitWidth = nil
        tab.splitStacked = false
        tab.groupID = nil
    }

    // MARK: Tab groups

    /// A page opened a link in a new tab (target=_blank, window.open, ⌘-click). The new tab joins
    /// the opener's group, creating one on first use, and lands after the group's last tab.
    @discardableResult
    public func openChild(url: URL?, from opener: BrowserTab, in space: Space) -> BrowserTab {
        let child = BrowserTab(url: url)
        let openerInToday = space.today.contains { $0 === opener }
        var group = space.group(opener.groupID) ?? space.groups.first { $0.openerID == opener.id }
        if group == nil {
            let title = opener.customTitle ?? (opener.url ?? opener.pinnedURL).map(URLInput.displayHost) ?? opener.displayTitle
            group = TabGroup(title: title.isEmpty ? opener.displayTitle : title, openerID: opener.id)
            space.groups.append(group!)
            if openerInToday { opener.groupID = group!.id }
        }
        let groupID = group!.id
        child.groupID = groupID
        if let last = space.today.lastIndex(where: { $0.groupID == groupID }) {
            space.today.insert(child, at: last + 1)
        } else if let i = space.today.firstIndex(where: { $0 === opener }) {
            space.today.insert(child, at: i + 1)
        } else {
            space.today.insert(child, at: 0)
        }
        // Opening into a collapsed group shows it again.
        if let i = space.groups.firstIndex(where: { $0.id == groupID }) { space.groups[i].isCollapsed = false }
        didChange()
        return child
    }

    public func renameGroup(_ id: UUID, to title: String, in space: Space) {
        guard let i = space.groups.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        space.groups[i].title = title
        didChange()
    }

    public func toggleGroupCollapsed(_ id: UUID, in space: Space) {
        guard let i = space.groups.firstIndex(where: { $0.id == id }) else { return }
        space.groups[i].isCollapsed.toggle()
        didChange()
    }

    /// A tab dragged out of its group leaves it (and any Split View inside it), landing just
    /// above or below the group.
    public func removeFromGroup(_ tab: BrowserTab, below: Bool, in space: Space) {
        guard let groupID = tab.groupID, space.today.contains(where: { $0 === tab }) else { return }
        space.today.removeAll { $0 === tab }
        tab.groupID = nil
        tab.splitID = nil
        tab.splitWidth = nil
        // The tab's links no longer feed the group.
        if let i = space.groups.firstIndex(where: { $0.id == groupID && $0.openerID == tab.id }) { space.groups[i].openerID = nil }
        let members = space.today.indices.filter { space.today[$0].groupID == groupID }
        let index = below ? (members.last.map { $0 + 1 } ?? space.today.count) : (members.first ?? 0)
        space.today.insert(tab, at: min(index, space.today.count))
        normalizeGroups(in: space)
        normalizeSplits(in: space)
        didChange()
    }

    /// Keeps the tabs, drops the grouping.
    public func ungroup(_ id: UUID, in space: Space) {
        for tab in space.today where tab.groupID == id { tab.groupID = nil }
        space.groups.removeAll { $0.id == id }
        didChange()
    }

    /// Archives every tab in the group.
    public func closeGroup(_ id: UUID, in space: Space) {
        for tab in space.members(of: id) { archive(tab) }
        space.groups.removeAll { $0.id == id }
        didChange()
    }

    /// A group of one is just a tab, so it dissolves; a group opened from a pinned tab or a
    /// Favorite lives on until it's empty.
    public func normalizeGroups(in space: Space) {
        for group in space.groups {
            let members = space.members(of: group.id)
            let openerIsMember = members.contains { $0.id == group.openerID }
            if members.isEmpty || (members.count == 1 && (openerIsMember || group.openerID == nil)) {
                for tab in members { tab.groupID = nil }
                space.groups.removeAll { $0.id == group.id }
            }
        }
    }

    /// ⌘W. Today tabs go to the Archive. Pinned tabs and favorites stay put; the caller unloads them.
    public func archive(_ tab: BrowserTab, reason: ArchivedTab.Reason = .manual) {
        guard case .today(let spaceID) = location(of: tab), let space = space(spaceID) else { return }
        space.today.removeAll { $0 === tab }
        tab.groupID = nil
        tab.splitID = nil
        normalizeGroups(in: space)
        normalizeSplits(in: space)
        archive.insert(ArchivedTab(id: tab.id, url: tab.url, title: tab.title, faviconURL: tab.faviconURL,
                                   spaceID: spaceID, archivedAt: .now, reason: reason), at: 0)
        if archive.count > 2000 { archive.removeLast(archive.count - 2000) }
        didChange()
    }

    /// Removes a Today tab without sending it to the Archive.
    public func discard(_ tab: BrowserTab) {
        for space in spaces where space.today.contains(where: { $0 === tab }) {
            space.today.removeAll { $0 === tab }
            tab.groupID = nil
            tab.splitID = nil
            normalizeGroups(in: space)
            normalizeSplits(in: space)
        }
        didChange()
    }

    /// ⇧⌘T. Brings the most recently archived tab back into its space's Today list.
    public func restoreLastArchived(fallback space: Space) -> BrowserTab? {
        guard !archive.isEmpty else { return nil }
        let item = archive.removeFirst()
        let target = self.space(item.spaceID) ?? space
        let tab = BrowserTab(id: item.id, url: item.url, title: item.title, faviconURL: item.faviconURL)
        target.today.insert(tab, at: 0)
        didChange()
        return tab
    }

    /// Brings a specific archived tab back to the top of `space`'s Today list.
    @discardableResult
    public func restore(_ item: ArchivedTab, into space: Space) -> BrowserTab {
        archive.removeAll { $0.id == item.id }
        let tab = BrowserTab(id: item.id, url: item.url, title: item.title, faviconURL: item.faviconURL)
        space.today.insert(tab, at: 0)
        didChange()
        return tab
    }

    /// ⌘D. Moves a tab between Today and the end of the pinned section.
    public func togglePin(_ tab: BrowserTab) {
        switch location(of: tab) {
        case .today(let spaceID)?:
            guard let space = space(spaceID) else { return }
            space.today.removeAll { $0 === tab }
            tab.pinnedURL = tab.url
            tab.groupID = nil
            tab.splitID = nil
            normalizeGroups(in: space)
            normalizeSplits(in: space)
            space.pinned.append(.tab(tab))
        case .pinned(let spaceID)?:
            guard let space = space(spaceID) else { return }
            removePinned(tab, from: space)
            tab.pinnedURL = nil
            space.today.insert(tab, at: 0)
        case .favorite?, nil:
            return
        }
        didChange()
    }

    public func addToFavorites(_ tab: BrowserTab) {
        guard favorites.count < 12, location(of: tab) != .favorite else { return }
        for space in spaces {
            space.today.removeAll { $0 === tab }
            removePinned(tab, from: space)
        }
        tab.pinnedURL = tab.pinnedURL ?? tab.url
        favorites.append(tab)
        didChange()
    }

    public func removeFromFavorites(_ tab: BrowserTab, to space: Space) {
        favorites.removeAll { $0 === tab }
        space.pinned.append(.tab(tab))
        didChange()
    }

    public func duplicate(_ tab: BrowserTab, in space: Space) -> BrowserTab {
        insertTab(url: tab.url, in: space, after: tab)
    }

    /// ⇧⌘K "Clear Unpinned Tabs": archives everything in Today except `keeping`.
    public func clearToday(in space: Space, keeping: BrowserTab? = nil) {
        for tab in space.today where tab !== keeping { archive(tab) }
    }

    /// Archives Today tabs idle longer than `autoArchiveAfter`. `protected` tabs (visible in a
    /// window right now) are never archived.
    public func autoArchive(now: Date = .now, protected: Set<UUID>) {
        guard autoArchiveAfter > 0 else { return } // "Never"
        for space in spaces {
            for tab in space.today where !protected.contains(tab.id)
                && now.timeIntervalSince(tab.lastActiveAt) > autoArchiveAfter {
                archive(tab, reason: .auto)
            }
        }
    }

    public func rename(_ tab: BrowserTab, to title: String?) {
        tab.customTitle = (title?.isEmpty ?? true) ? nil : title
        didChange()
    }

    /// Moves a tab to another Space, keeping it pinned if it was pinned.
    public func move(_ tab: BrowserTab, to target: Space) {
        guard let location = location(of: tab) else { return }
        switch location {
        case .today(let id):
            space(id)?.today.removeAll { $0 === tab }
            tab.groupID = nil
            tab.splitID = nil
            if let source = space(id) { normalizeGroups(in: source); normalizeSplits(in: source) }
            target.today.insert(tab, at: 0)
        case .pinned(let id):
            if let space = space(id) { removePinned(tab, from: space) }
            target.pinned.append(.tab(tab))
        case .favorite:
            return
        }
        didChange()
    }

    // MARK: Reordering

    public enum InsertPosition: Sendable { case before, after }

    /// Drag to reorder: puts `tab` just before or after the sidebar item `nodeID` (a tab, a Split
    /// View pane or a folder), taking on that place: pinned (in the same folder) or Today (in the
    /// same group). A tab dragged out of a Split View leaves it.
    public func move(_ tab: BrowserTab, _ position: InsertPosition, _ nodeID: UUID, in space: Space) {
        guard tab.id != nodeID, location(of: tab) != .favorite else { return }
        let pinnedURL = tab.pinnedURL ?? tab.url
        detach(tab, keepingIn: space)
        if let (folder, index) = Self.pinnedPosition(of: nodeID, in: space.pinned) {
            tab.pinnedURL = pinnedURL
            let at = position == .before ? index : index + 1
            if let folder { folder.children.insert(.tab(tab), at: at) } else { space.pinned.insert(.tab(tab), at: at) }
        } else if let target = space.today.first(where: { $0.id == nodeID }) {
            let run = target.splitID.map { id in space.today.indices.filter { space.today[$0].splitID == id } }
                ?? [space.today.firstIndex { $0 === target } ?? 0]
            let at = position == .before ? (run.first ?? 0) : (run.last ?? -1) + 1
            tab.groupID = target.groupID
            space.today.insert(tab, at: min(at, space.today.count))
        } else {
            space.today.insert(tab, at: 0)
        }
        normalizeGroups(in: space)
        normalizeSplits(in: space)
        didChange()
    }

    /// Dropped on the New Tab row: the top of Today.
    public func moveToTodayTop(_ tab: BrowserTab, in space: Space) {
        guard location(of: tab) != .favorite else { return }
        detach(tab, keepingIn: space)
        space.today.insert(tab, at: 0)
        normalizeGroups(in: space)
        normalizeSplits(in: space)
        didChange()
    }

    /// Dropped on a folder: pinned, at the end of the folder, which opens to show it.
    public func move(_ tab: BrowserTab, into folder: Folder, in space: Space) {
        guard location(of: tab) != .favorite else { return }
        let pinnedURL = tab.pinnedURL ?? tab.url
        detach(tab, keepingIn: space)
        tab.pinnedURL = pinnedURL
        folder.children.append(.tab(tab))
        folder.isExpanded = true
        normalizeGroups(in: space)
        normalizeSplits(in: space)
        didChange()
    }

    /// A node's folder in the pinned tree (nil at the top level) and its index there.
    static func pinnedPosition(of id: UUID, in nodes: [SidebarNode], parent: Folder? = nil) -> (Folder?, Int)? {
        for (index, node) in nodes.enumerated() {
            if node.id == id { return (parent, index) }
            if case .folder(let folder) = node, let found = pinnedPosition(of: id, in: folder.children, parent: folder) { return found }
        }
        return nil
    }

    // MARK: Folders

    @discardableResult
    public func newFolder(in space: Space, title: String = "New Folder") -> Folder {
        let folder = Folder(title: title)
        space.pinned.insert(.folder(folder), at: 0)
        didChange()
        return folder
    }

    public func setFoldersExpanded(_ expanded: Bool, in space: Space) {
        func walk(_ nodes: [SidebarNode]) {
            for case .folder(let folder) in nodes {
                folder.isExpanded = expanded
                walk(folder.children)
            }
        }
        walk(space.pinned)
        didChange()
    }

    public func toggle(_ folder: Folder) {
        folder.isExpanded.toggle()
        didChange()
    }

    // MARK: Profiles

    /// Profiles in use: "default" first, then the others by name.
    public var profiles: [String] {
        ["default"] + Set(spaces.map(\.profile)).subtracting(["default"]).sorted()
    }

    /// A Space's tabs use the profile's cookies and site data.
    public func setProfile(_ profile: String, for space: Space) {
        let name = profile.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != space.profile else { return }
        space.profile = name
        didChange()
    }

    // MARK: Spaces

    @discardableResult
    public func newSpace(title: String, theme: SpaceTheme) -> Space {
        let space = Space(title: title, theme: theme)
        spaces.append(space)
        didChange()
        return space
    }

    public func rename(_ space: Space, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        space.title = trimmed
        didChange()
    }

    public func setIcon(_ icon: String?, for space: Space) {
        space.icon = (icon?.isEmpty ?? true) ? nil : icon
        didChange()
    }

    /// Archives the Space's Today tabs and removes it. The last Space can't be deleted.
    @discardableResult
    public func delete(_ space: Space) -> Bool {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0 === space }) else { return false }
        for tab in space.today { archive(tab) }
        spaces.remove(at: index)
        didChange()
        return true
    }

    // MARK: Private

    private func removePinned(_ tab: BrowserTab, from space: Space) {
        func strip(_ nodes: inout [SidebarNode]) {
            nodes.removeAll { if case .tab(let t) = $0 { return t === tab } else { return false } }
            for case .folder(let folder) in nodes { strip(&folder.children) }
        }
        strip(&space.pinned)
    }
}
