import Foundation
import SQLite3

/// What can be brought over from Arc: Spaces with their pinned tree and open (Today) tabs,
/// Favorites, and browsing history (passwords: `ArcPasswords`). Read-only; Arc's files are
/// never modified.
public struct ArcImport: Sendable {
    public struct Tab: Sendable, Equatable {
        public var url: URL
        public var title: String?
        /// Set when the tab was renamed in Arc.
        public var customTitle: String?
        public var lastActiveAt: Date?
    }

    public indirect enum Node: Sendable, Equatable {
        case tab(Tab)
        case folder(title: String, children: [Node])
    }

    public struct SpaceInfo: Sendable, Equatable {
        public var title: String
        public var icon: String?
        public var pinned: [Node]
        public var today: [Tab]
    }

    public var spaces: [SpaceInfo] = []
    public var favorites: [Tab] = []
    public var history: [HistoryEntry] = []

    public var pinnedTabCount: Int {
        func count(_ nodes: [Node]) -> Int {
            nodes.reduce(0) { total, node in
                switch node {
                case .tab: total + 1
                case .folder(_, let children): total + count(children)
                }
            }
        }
        return spaces.reduce(0) { $0 + count($1.pinned) }
    }

    public var folderCount: Int {
        func count(_ nodes: [Node]) -> Int {
            nodes.reduce(0) { total, node in
                if case .folder(_, let children) = node { return total + 1 + count(children) }
                return total
            }
        }
        return spaces.reduce(0) { $0 + count($1.pinned) }
    }

    public var todayTabCount: Int { spaces.reduce(0) { $0 + $1.today.count } }
}

public enum ArcImporter {
    public static var arcDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Arc", directoryHint: .isDirectory)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: arcDirectory.appending(path: "StorableSidebar.json").path(percentEncoded: false))
    }

    /// Reads everything available. History is optional because it means copying a SQLite file.
    public static func load(includeHistory: Bool, from directory: URL = arcDirectory) throws -> ArcImport {
        let data = try Data(contentsOf: directory.appending(path: "StorableSidebar.json"))
        var result = try parseSidebar(data)
        if includeHistory {
            result.history = readHistory(userData: directory.appending(path: "User Data", directoryHint: .isDirectory))
        }
        return result
    }

    // MARK: Sidebar (StorableSidebar.json)

    enum ImportError: Error { case unrecognizedFormat }

    /// Arc encodes Swift dictionaries as flat alternating `[key, value, key, value]` arrays and enum
    /// cases as `{case: {_0: payload}}`. The main sidebar is the container after the `global` key.
    public static func parseSidebar(_ data: Data) throws -> ArcImport {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any],
              let globalIndex = containers.firstIndex(where: { ($0 as? [String: Any])?["global"] != nil }),
              globalIndex + 1 < containers.count,
              let main = containers[globalIndex + 1] as? [String: Any] else { throw ImportError.unrecognizedFormat }

        let items = Dictionary(((main["items"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
            .compactMap { item in (item["id"] as? String).map { ($0, item) } }, uniquingKeysWith: { a, _ in a })

        func tab(_ item: [String: Any]) -> ArcImport.Tab? {
            guard let data = item["data"] as? [String: Any], let tab = data["tab"] as? [String: Any],
                  let urlString = tab["savedURL"] as? String, let url = URL(string: urlString) else { return nil }
            let lastActive = (tab["timeLastActiveAt"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
            return ArcImport.Tab(url: url, title: tab["savedTitle"] as? String,
                                 customTitle: (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }, lastActiveAt: lastActive)
        }

        func nodes(childrenOf id: String?, depth: Int = 0) -> [ArcImport.Node] {
            guard depth < 16, let id, let children = items[id]?["childrenIds"] as? [String] else { return [] }
            return children.compactMap { childID -> ArcImport.Node? in
                guard let item = items[childID], let data = item["data"] as? [String: Any] else { return nil }
                if data["list"] != nil {
                    return .folder(title: (item["title"] as? String) ?? "Folder", children: nodes(childrenOf: childID, depth: depth + 1))
                }
                return tab(item).map(ArcImport.Node.tab)
            }
        }

        var result = ArcImport()
        for case let space as [String: Any] in (main["spaces"] as? [Any]) ?? [] {
            // containerIDs: ["pinned", <id>, "unpinned", <id>] in either order.
            let ids = (space["containerIDs"] as? [Any]) ?? []
            var pinnedID: String?, unpinnedID: String?
            for i in stride(from: 0, to: ids.count - 1, by: 2) {
                if ids[i] as? String == "pinned" { pinnedID = ids[i + 1] as? String }
                if ids[i] as? String == "unpinned" { unpinnedID = ids[i + 1] as? String }
            }
            let iconType = (space["customInfo"] as? [String: Any])?["iconType"] as? [String: Any]
            let icon = (iconType?["emoji_v2"] ?? iconType?["emoji"] ?? iconType?["icon"]) as? String
            let today = nodes(childrenOf: unpinnedID).compactMap { node -> ArcImport.Tab? in
                if case .tab(let tab) = node { return tab }
                return nil
            }
            result.spaces.append(ArcImport.SpaceInfo(
                title: (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space",
                icon: icon.flatMap { $0.unicodeScalars.first?.properties.isEmojiPresentation == true ? $0 : nil },
                pinned: nodes(childrenOf: pinnedID), today: today))
        }

        // topAppsContainerIDs: [{default: true}, <id>, …]; the default profile's Favorites.
        let topApps = (main["topAppsContainerIDs"] as? [Any]) ?? []
        if let favoritesID = topApps.compactMap({ $0 as? String }).first {
            result.favorites = nodes(childrenOf: favoritesID).compactMap {
                if case .tab(let tab) = $0 { return tab }
                return nil
            }
        }
        return result
    }

    // MARK: History (Chromium SQLite)

    /// Merges `History` from every Chromium profile. The databases are copied first because Arc
    /// keeps them locked while running.
    public static func readHistory(userData: URL, limit: Int = 20_000) -> [HistoryEntry] {
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: userData.path(percentEncoded: false))) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        var byURL: [String: HistoryEntry] = [:]
        for profile in profiles {
            let source = userData.appending(path: profile).appending(path: "History")
            for entry in readHistoryDatabase(source, limit: limit) {
                if let existing = byURL[entry.id] {
                    byURL[entry.id] = existing.lastVisit >= entry.lastVisit ? existing : entry
                    byURL[entry.id]?.visitCount = existing.visitCount + entry.visitCount
                } else {
                    byURL[entry.id] = entry
                }
            }
        }
        return byURL.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit).map { $0 }
    }

    static func readHistoryDatabase(_ source: URL, limit: Int) -> [HistoryEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { return [] }
        let temp = fm.temporaryDirectory.appending(path: "bezier-arc-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-journal"] where fm.fileExists(atPath: source.path(percentEncoded: false) + suffix) {
                try fm.copyItem(atPath: source.path(percentEncoded: false) + suffix, toPath: temp.appending(path: "History" + suffix).path(percentEncoded: false))
            }
        } catch { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appending(path: "History").path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlText = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: urlText)),
                  let scheme = url.scheme, scheme == "http" || scheme == "https" else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            // Chromium time: microseconds since 1601-01-01 UTC.
            let chromium = sqlite3_column_int64(statement, 3)
            let date = Date(timeIntervalSince1970: Double(chromium) / 1_000_000 - 11_644_473_600)
            entries.append(HistoryEntry(url: url, title: (title?.isEmpty ?? true) ? nil : title, faviconURL: nil,
                                        lastVisit: date, visitCount: max(1, Int(sqlite3_column_int(statement, 2)))))
        }
        return entries
    }
}

// MARK: - Applying an import

public struct ArcImportSummary: Sendable, Equatable {
    public var spacesAdded = 0
    public var spacesMerged = 0
    public var pinnedTabs = 0
    public var folders = 0
    public var todayTabs = 0
    public var favorites = 0
    public var historyEntries = 0
    public var passwords = 0
    /// Saved passwords that couldn't be decrypted.
    public var passwordsFailed = 0
}

public struct ArcImportOptions: Sendable {
    public var spaces = true
    public var todayTabs = true
    public var favorites = true
    public var history = true
    public var passwords = true
    public init() {}
}

extension BrowserModel {
    /// Adds Arc's Spaces (merging into a same-named Space), skipping tabs whose URL is already
    /// there, so importing twice doesn't duplicate anything. Imported Spaces get neutral themes
    /// with distinct accents (Arc doesn't store theme colours in its sidebar file).
    @discardableResult
    public func apply(_ arc: ArcImport, options: ArcImportOptions, history: HistoryStore?) -> ArcImportSummary {
        var summary = ArcImportSummary()

        if options.spaces {
            for info in arc.spaces {
                let target: Space
                if let existing = spaces.first(where: { $0.title.caseInsensitiveCompare(info.title) == .orderedSame }) {
                    target = existing
                    summary.spacesMerged += 1
                } else {
                    target = Space(title: info.title, icon: info.icon, theme: .newSpaceDefault(index: spaces.count))
                    spaces.append(target)
                    summary.spacesAdded += 1
                }
                var known = Set((target.allPinnedTabs + target.today).compactMap { $0.url?.absoluteString })

                func convert(_ nodes: [ArcImport.Node]) -> [SidebarNode] {
                    nodes.compactMap { node in
                        switch node {
                        case .tab(let tab):
                            guard known.insert(tab.url.absoluteString).inserted else { return nil }
                            summary.pinnedTabs += 1
                            return .tab(BrowserTab(url: tab.url, title: tab.title, pinnedURL: tab.url, customTitle: tab.customTitle,
                                                   lastActiveAt: tab.lastActiveAt ?? .now))
                        case .folder(let title, let children):
                            summary.folders += 1
                            return .folder(Folder(title: title, isExpanded: false, children: convert(children)))
                        }
                    }
                }
                target.pinned += convert(info.pinned)

                if options.todayTabs {
                    for tab in info.today where known.insert(tab.url.absoluteString).inserted {
                        target.today.append(BrowserTab(url: tab.url, title: tab.title, customTitle: tab.customTitle,
                                                       lastActiveAt: .now))
                        summary.todayTabs += 1
                    }
                }
            }
        }

        if options.favorites {
            var known = Set(favorites.compactMap { $0.url?.absoluteString })
            for tab in arc.favorites where favorites.count < 12 && known.insert(tab.url.absoluteString).inserted {
                favorites.append(BrowserTab(url: tab.url, title: tab.title, pinnedURL: tab.url, customTitle: tab.customTitle))
                summary.favorites += 1
            }
        }

        if options.history, let history {
            summary.historyEntries = history.merge(arc.history)
        }
        didChange()
        return summary
    }
}

extension HistoryStore {
    /// Adds entries, keeping the newer visit and the larger count for URLs already present.
    /// Returns how many URLs were new.
    @discardableResult
    public func merge(_ incoming: [HistoryEntry]) -> Int {
        var added = 0
        for entry in incoming {
            if let existing = entries[entry.id] {
                var merged = existing
                merged.visitCount = max(existing.visitCount, entry.visitCount)
                if entry.lastVisit > existing.lastVisit { merged.lastVisit = entry.lastVisit }
                if merged.title == nil { merged.title = entry.title }
                replace(merged)
            } else {
                replace(entry)
                added += 1
            }
        }
        return added
    }
}
