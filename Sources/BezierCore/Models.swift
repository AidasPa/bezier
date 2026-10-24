import Foundation
import Observation

/// A browser tab. Lives in a Space's pinned tree, its Today list, or the global Favorites.
@MainActor
@Observable
public final class BrowserTab: Identifiable {
    public let id: UUID
    public var url: URL?
    public var title: String?
    public var faviconURL: URL?
    /// For pinned tabs and favorites: the URL the tab resets to. `nil` for Today tabs.
    public var pinnedURL: URL?
    public var customTitle: String?
    public var lastActiveAt: Date
    public let createdAt: Date
    /// Today tabs opened from a page share a group with it (see `BrowserModel.openChild`).
    public var groupID: UUID?
    /// Tabs shown side by side (Split View) share this; they sit next to each other in Today.
    public var splitID: UUID?
    /// This pane's share of its Split View's width (or height, stacked); `nil` until a divider is dragged.
    public var splitWidth: Double?
    /// The Split View is arranged top to bottom instead of side by side.
    public var splitStacked = false

    public init(id: UUID = UUID(), url: URL?, title: String? = nil, faviconURL: URL? = nil,
                pinnedURL: URL? = nil, customTitle: String? = nil,
                lastActiveAt: Date = .now, createdAt: Date = .now, groupID: UUID? = nil, splitID: UUID? = nil,
                splitWidth: Double? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.pinnedURL = pinnedURL
        self.customTitle = customTitle
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.groupID = groupID
        self.splitID = splitID
        self.splitWidth = splitWidth
    }

    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let title, !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }

    /// A pinned tab that navigated away from its pinned page shows a "/" before its title.
    public var hasDriftedFromPinnedURL: Bool {
        guard let pinnedURL, let url else { return false }
        func host(_ u: URL) -> String { (u.host() ?? "").replacing(/^www\./, with: "") }
        func path(_ u: URL) -> String { u.path(percentEncoded: false).hasSuffix("/") ? String(u.path(percentEncoded: false).dropLast()) : u.path(percentEncoded: false) }
        return host(pinnedURL) != host(url) || path(pinnedURL) != path(url)
    }
}

@MainActor
@Observable
public final class Folder: Identifiable {
    public let id: UUID
    public var title: String
    public var isExpanded: Bool
    public var children: [SidebarNode]

    public init(id: UUID = UUID(), title: String, isExpanded: Bool = true, children: [SidebarNode] = []) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.children = children
    }
}

@MainActor
public enum SidebarNode: @MainActor Identifiable {
    case tab(BrowserTab)
    case folder(Folder)

    public var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .folder(let folder): folder.id
        }
    }
}

@MainActor
@Observable
public final class Space: Identifiable {
    public let id: UUID
    public var title: String
    /// Emoji or SF Symbol name shown in the footer switcher and space header.
    public var icon: String?
    public var theme: SpaceTheme
    public var profile: String
    public var pinned: [SidebarNode]
    /// Unpinned tabs, newest first. Auto-archived after inactivity. Members of a group are
    /// kept next to each other.
    public var today: [BrowserTab]
    public var groups: [TabGroup]

    public init(id: UUID = UUID(), title: String, icon: String? = nil, theme: SpaceTheme,
                profile: String = "default", pinned: [SidebarNode] = [], today: [BrowserTab] = [], groups: [TabGroup] = []) {
        self.id = id
        self.title = title
        self.icon = icon
        self.theme = theme
        self.profile = profile
        self.pinned = pinned
        self.today = today
        self.groups = groups
    }

    public func group(_ id: UUID?) -> TabGroup? { groups.first { $0.id == id } }

    public func members(of groupID: UUID) -> [BrowserTab] { today.filter { $0.groupID == groupID } }

    /// Tabs of a Split View, left to right.
    public func panes(of splitID: UUID) -> [BrowserTab] { today.filter { $0.splitID == splitID } }

    /// Pinned tabs in sidebar order, descending into expanded and collapsed folders.
    public var allPinnedTabs: [BrowserTab] {
        func walk(_ nodes: [SidebarNode]) -> [BrowserTab] {
            nodes.flatMap { node -> [BrowserTab] in
                switch node {
                case .tab(let tab): [tab]
                case .folder(let folder): walk(folder.children)
                }
            }
        }
        return walk(pinned)
    }

    /// Tabs in visual order: visible pinned tabs, then Today.
    public var visibleTabs: [BrowserTab] {
        func walk(_ nodes: [SidebarNode]) -> [BrowserTab] {
            nodes.flatMap { node -> [BrowserTab] in
                switch node {
                case .tab(let tab): [tab]
                case .folder(let folder): folder.isExpanded ? walk(folder.children) : []
                }
            }
        }
        return walk(pinned) + today
    }
}

/// A run of Today tabs opened from the same page.
public struct TabGroup: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var isCollapsed: Bool
    /// The tab whose links fill this group. It's a member unless it's pinned or a Favorite.
    public var openerID: UUID?

    public init(id: UUID = UUID(), title: String, isCollapsed: Bool = false, openerID: UUID? = nil) {
        self.id = id
        self.title = title
        self.isCollapsed = isCollapsed
        self.openerID = openerID
    }
}

public struct ArchivedTab: Codable, Identifiable, Sendable {
    public enum Reason: String, Codable, Sendable { case auto, manual }

    public var id: UUID
    public var url: URL?
    public var title: String?
    public var faviconURL: URL?
    public var spaceID: UUID?
    public var archivedAt: Date
    public var reason: Reason
}
