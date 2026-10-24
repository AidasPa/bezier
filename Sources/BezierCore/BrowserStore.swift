import Foundation

/// JSON persistence for `BrowserModel`, debounced. Mirrors Arc's StorableSidebar.json idea:
/// one document holding spaces, the pinned tree, Today, favorites and the archive.
@MainActor
public final class BrowserStore {
    public let fileURL: URL
    private var pendingSave: Task<Void, Never>?

    public init(directory: URL = BrowserStore.defaultDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "Sidebar.json")
    }

    public nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Bezier", directoryHint: .isDirectory)
    }

    public func load() -> BrowserModel {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder.store.decode(BrowserSnapshot.self, from: data) else {
            return Self.firstRunModel()
        }
        return snapshot.makeModel()
    }

    public func scheduleSave(_ model: BrowserModel) {
        pendingSave?.cancel()
        pendingSave = Task { [fileURL] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            let data = try? JSONEncoder.store.encode(BrowserSnapshot(model))
            await Task.detached(priority: .utility) {
                try? data?.write(to: fileURL, options: .atomic)
            }.value
        }
    }

    public func saveNow(_ model: BrowserModel) {
        pendingSave?.cancel()
        try? JSONEncoder.store.encode(BrowserSnapshot(model)).write(to: fileURL, options: .atomic)
    }

    static func firstRunModel() -> BrowserModel {
        func tab(_ s: String, _ title: String, pinned: Bool = true) -> BrowserTab {
            let url = URL(string: s)!
            return BrowserTab(url: url, title: title, pinnedURL: pinned ? url : nil)
        }
        let personal = Space(
            title: "Personal", icon: "🏡", theme: .neutral,
            pinned: [
                .folder(Folder(title: "Reading", children: [
                    .tab(tab("https://news.ycombinator.com", "Hacker News")),
                    .tab(tab("https://en.wikipedia.org/wiki/Special:Random", "Random article")),
                ])),
                .tab(tab("https://developer.apple.com", "Apple Developer")),
            ],
            today: [tab("https://arc.net", "A farewell to Arc", pinned: false)]
        )
        let work = Space(
            title: "Work", icon: "💼", theme: .sky,
            pinned: [.tab(tab("https://github.com", "GitHub")), .tab(tab("https://linear.app", "Linear"))]
        )
        return BrowserModel(
            spaces: [personal, work],
            favorites: [tab("https://www.youtube.com", "YouTube"), tab("https://github.com", "GitHub"), tab("https://www.figma.com", "Figma")]
        )
    }
}

// MARK: - Snapshot (Codable mirror of the observable model)

struct BrowserSnapshot: Codable {
    var version = 1
    var spaces: [SpaceSnapshot]
    var favorites: [TabSnapshot]
    var archive: [ArchivedTab]
    var autoArchiveAfter: TimeInterval

    @MainActor init(_ model: BrowserModel) {
        spaces = model.spaces.map(SpaceSnapshot.init)
        favorites = model.favorites.map(TabSnapshot.init)
        archive = model.archive
        autoArchiveAfter = model.autoArchiveAfter
    }

    @MainActor func makeModel() -> BrowserModel {
        let model = BrowserModel(spaces: spaces.map { $0.make() }, favorites: favorites.map { $0.make() }, archive: archive)
        model.autoArchiveAfter = autoArchiveAfter
        return model
    }
}

struct SpaceSnapshot: Codable {
    var id: UUID
    var title: String
    var icon: String?
    var theme: SpaceTheme
    var profile: String
    var pinned: [NodeSnapshot]
    var today: [TabSnapshot]
    var groups: [TabGroup]?

    @MainActor init(_ space: Space) {
        id = space.id; title = space.title; icon = space.icon; theme = space.theme; profile = space.profile
        pinned = space.pinned.map(NodeSnapshot.init)
        today = space.today.map(TabSnapshot.init)
        groups = space.groups
    }

    @MainActor func make() -> Space {
        Space(id: id, title: title, icon: icon, theme: theme, profile: profile,
              pinned: pinned.map { $0.make() }, today: today.map { $0.make() }, groups: groups ?? [])
    }
}

indirect enum NodeSnapshot: Codable {
    case tab(TabSnapshot)
    case folder(FolderSnapshot)

    @MainActor init(_ node: SidebarNode) {
        switch node {
        case .tab(let tab): self = .tab(TabSnapshot(tab))
        case .folder(let folder): self = .folder(FolderSnapshot(folder))
        }
    }

    @MainActor func make() -> SidebarNode {
        switch self {
        case .tab(let tab): .tab(tab.make())
        case .folder(let folder): .folder(folder.make())
        }
    }
}

struct FolderSnapshot: Codable {
    var id: UUID
    var title: String
    var isExpanded: Bool
    var children: [NodeSnapshot]

    @MainActor init(_ folder: Folder) {
        id = folder.id; title = folder.title; isExpanded = folder.isExpanded
        children = folder.children.map(NodeSnapshot.init)
    }

    @MainActor func make() -> Folder {
        Folder(id: id, title: title, isExpanded: isExpanded, children: children.map { $0.make() })
    }
}

struct TabSnapshot: Codable {
    var id: UUID
    var url: URL?
    var title: String?
    var faviconURL: URL?
    var pinnedURL: URL?
    var customTitle: String?
    var lastActiveAt: Date
    var createdAt: Date
    var groupID: UUID?
    var splitID: UUID?
    var splitWidth: Double?
    var splitStacked: Bool?

    @MainActor init(_ tab: BrowserTab) {
        id = tab.id; url = tab.url; title = tab.title; faviconURL = tab.faviconURL
        pinnedURL = tab.pinnedURL; customTitle = tab.customTitle
        lastActiveAt = tab.lastActiveAt; createdAt = tab.createdAt; groupID = tab.groupID; splitID = tab.splitID
        splitWidth = tab.splitWidth
        splitStacked = tab.splitStacked ? true : nil
    }

    @MainActor func make() -> BrowserTab {
        let tab = BrowserTab(id: id, url: url, title: title, faviconURL: faviconURL, pinnedURL: pinnedURL,
            customTitle: customTitle, lastActiveAt: lastActiveAt, createdAt: createdAt, groupID: groupID, splitID: splitID,
            splitWidth: splitWidth)
        tab.splitStacked = splitStacked ?? false
        return tab
    }
}

extension JSONEncoder {
    static var store: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var store: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
