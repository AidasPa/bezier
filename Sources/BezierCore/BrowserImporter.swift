import Foundation
import SQLite3

/// Bookmarks, history and (Chromium browsers) passwords from other browsers. Read-only.
public enum ImportSource: String, CaseIterable, Identifiable, Sendable {
    case chrome, brave, edge, vivaldi, chromium, safari, firefox

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        case .safari: "Safari"
        case .firefox: "Firefox"
        }
    }

    /// Chromium browsers: the user data folder and the keychain item their passwords use.
    public var chromium: (folder: String, service: String, account: String)? {
        switch self {
        case .chrome: ("Google/Chrome", "Chrome Safe Storage", "Chrome")
        case .brave: ("BraveSoftware/Brave-Browser", "Brave Safe Storage", "Brave")
        case .edge: ("Microsoft Edge", "Microsoft Edge Safe Storage", "Microsoft Edge")
        case .vivaldi: ("Vivaldi", "Vivaldi Safe Storage", "Vivaldi")
        case .chromium: ("Chromium", "Chromium Safe Storage", "Chromium")
        case .safari, .firefox: nil
        }
    }

    public var dataDirectory: URL {
        let support = URL.applicationSupportDirectory
        if let chromium { return support.appending(path: chromium.folder, directoryHint: .isDirectory) }
        switch self {
        case .safari: return URL.libraryDirectory.appending(path: "Safari", directoryHint: .isDirectory)
        default: return support.appending(path: "Firefox/Profiles", directoryHint: .isDirectory)
        }
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: dataDirectory.path(percentEncoded: false)) }
    public var hasPasswords: Bool { chromium != nil }

    public static var installed: [ImportSource] { allCases.filter(\.isInstalled) }
}

public struct BrowserImport: Sendable {
    public var bookmarks: [ArcImport.Node] = []
    public var history: [HistoryEntry] = []

    public var bookmarkCount: Int {
        func count(_ nodes: [ArcImport.Node]) -> Int {
            nodes.reduce(0) { total, node in
                if case .folder(_, let children) = node { return total + count(children) }
                return total + 1
            }
        }
        return count(bookmarks)
    }
}

public enum BrowserImporter {
    public enum ImportError: Error { case unreadable }

    public static func load(_ source: ImportSource, from directory: URL? = nil, includeHistory: Bool) throws -> BrowserImport {
        let directory = directory ?? source.dataDirectory
        switch source {
        case .safari: return try loadSafari(directory, includeHistory: includeHistory)
        case .firefox: return try loadFirefox(directory, includeHistory: includeHistory)
        default: return try loadChromium(directory, includeHistory: includeHistory)
        }
    }

    // MARK: Chromium (Chrome, Brave, Edge, Vivaldi)

    static func loadChromium(_ userData: URL, includeHistory: Bool) throws -> BrowserImport {
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: userData.path(percentEncoded: false))) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        var result = BrowserImport()
        for profile in profiles {
            let file = userData.appending(path: profile).appending(path: "Bookmarks")
            guard let data = try? Data(contentsOf: file) else { continue }
            result.bookmarks += parseChromiumBookmarks(data)
        }
        guard !profiles.isEmpty else { throw ImportError.unreadable }
        if includeHistory { result.history = ArcImporter.readHistory(userData: userData) }
        return result
    }

    /// `roots.bookmark_bar` and `roots.other`: folders of `{type: "url"|"folder", name, url, children}`.
    public static func parseChromiumBookmarks(_ data: Data) -> [ArcImport.Node] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return [] }
        func nodes(_ list: [Any], depth: Int) -> [ArcImport.Node] {
            guard depth < 16 else { return [] }
            return list.compactMap { item -> ArcImport.Node? in
                guard let item = item as? [String: Any] else { return nil }
                let name = item["name"] as? String ?? ""
                if item["type"] as? String == "folder" {
                    return .folder(title: name.isEmpty ? "Folder" : name, children: nodes(item["children"] as? [Any] ?? [], depth: depth + 1))
                }
                guard let url = (item["url"] as? String).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
                return .tab(ArcImport.Tab(url: url, title: name.isEmpty ? nil : name, customTitle: nil, lastActiveAt: nil))
            }
        }
        var result: [ArcImport.Node] = []
        for (key, title) in [("bookmark_bar", "Bookmarks Bar"), ("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
            guard let folder = roots[key] as? [String: Any] else { continue }
            let children = nodes(folder["children"] as? [Any] ?? [], depth: 0)
            if !children.isEmpty { result.append(.folder(title: title, children: children)) }
        }
        return result
    }

    // MARK: Safari

    static func loadSafari(_ directory: URL, includeHistory: Bool) throws -> BrowserImport {
        // Safari's files need Full Disk Access; without it they read as missing.
        guard let data = try? Data(contentsOf: directory.appending(path: "Bookmarks.plist")) else { throw ImportError.unreadable }
        var result = BrowserImport(bookmarks: parseSafariBookmarks(data))
        if includeHistory { result.history = readSafariHistory(directory.appending(path: "History.db")) }
        return result
    }

    /// Nested `Children` of `WebBookmarkTypeList` folders and `WebBookmarkTypeLeaf` bookmarks.
    public static func parseSafariBookmarks(_ data: Data) -> [ArcImport.Node] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        func nodes(_ list: [Any], depth: Int) -> [ArcImport.Node] {
            guard depth < 16 else { return [] }
            return list.compactMap { item -> ArcImport.Node? in
                guard let item = item as? [String: Any] else { return nil }
                switch item["WebBookmarkType"] as? String {
                case "WebBookmarkTypeList":
                    let title = item["Title"] as? String ?? "Folder"
                    guard title != "com.apple.ReadingList" else { return nil }
                    let name = ["BookmarksBar": "Favorites Bar", "BookmarksMenu": "Bookmarks Menu"][title] ?? title
                    return .folder(title: name, children: nodes(item["Children"] as? [Any] ?? [], depth: depth + 1))
                case "WebBookmarkTypeLeaf":
                    guard let url = (item["URLString"] as? String).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
                    let title = (item["URIDictionary"] as? [String: Any])?["title"] as? String
                    return .tab(ArcImport.Tab(url: url, title: title, customTitle: nil, lastActiveAt: nil))
                default:
                    return nil
                }
            }
        }
        return nodes(root["Children"] as? [Any] ?? [], depth: 0).filter {
            if case .folder(_, let children) = $0 { return !children.isEmpty }
            return true
        }
    }

    static func readSafariHistory(_ source: URL, limit: Int = 20_000) -> [HistoryEntry] {
        // Core Data time: seconds since 2001-01-01.
        query(copyOf: source, sql: """
            SELECT i.url, (SELECT title FROM history_visits WHERE history_item = i.id ORDER BY visit_time DESC LIMIT 1),
                   i.visit_count, (SELECT MAX(visit_time) FROM history_visits WHERE history_item = i.id) AS last
            FROM history_items i ORDER BY last DESC LIMIT \(limit)
            """) { row in
            guard let url = row.text(0).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
            return HistoryEntry(url: url, title: row.text(1), faviconURL: nil, lastVisit: Date(timeIntervalSinceReferenceDate: row.double(3)),
                                visitCount: max(1, row.int(2)))
        }
    }

    // MARK: Firefox

    static func loadFirefox(_ profiles: URL, includeHistory: Bool) throws -> BrowserImport {
        // The profile with the most recently used places database.
        let candidates = ((try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: "places.sqlite") }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        guard let places = candidates.max(by: { modified($0) < modified($1) }) else { throw ImportError.unreadable }
        var result = BrowserImport(bookmarks: readFirefoxBookmarks(places))
        if includeHistory { result.history = readFirefoxHistory(places) }
        return result
    }

    /// `moz_bookmarks` (type 1 bookmark, 2 folder) under the toolbar, menu and unfiled roots.
    static func readFirefoxBookmarks(_ places: URL) -> [ArcImport.Node] {
        struct Mark { var id: Int; var type: Int; var parent: Int; var position: Int; var title: String?; var url: String?; var guid: String? }
        let rows: [Mark] = query(copyOf: places, sql: """
            SELECT b.id, b.type, b.parent, b.position, b.title, p.url, b.guid FROM moz_bookmarks b
            LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
            """) { r in Mark(id: r.int(0), type: r.int(1), parent: r.int(2), position: r.int(3), title: r.text(4), url: r.text(5), guid: r.text(6)) }
        let children = Dictionary(grouping: rows, by: \.parent)
        func nodes(_ parent: Int, depth: Int) -> [ArcImport.Node] {
            guard depth < 16 else { return [] }
            return (children[parent] ?? []).compactMap { row -> ArcImport.Node? in
                if row.type == 2 { return .folder(title: row.title ?? "Folder", children: nodes(row.id, depth: depth + 1)) }
                guard row.type == 1, let url = row.url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
                return .tab(ArcImport.Tab(url: url, title: row.title, customTitle: nil, lastActiveAt: nil))
            }
        }
        let roots: [(String, String)] = [("toolbar_____", "Bookmarks Toolbar"), ("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks")]
        return roots.compactMap { guid, title in
            guard let root = rows.first(where: { $0.guid == guid }) else { return nil }
            let items = nodes(root.id, depth: 0)
            return items.isEmpty ? nil : .folder(title: title, children: items)
        }
    }

    static func readFirefoxHistory(_ places: URL, limit: Int = 20_000) -> [HistoryEntry] {
        // last_visit_date: microseconds since 1970.
        query(copyOf: places, sql: """
            SELECT url, title, visit_count, last_visit_date FROM moz_places
            WHERE last_visit_date IS NOT NULL AND hidden = 0 ORDER BY last_visit_date DESC LIMIT \(limit)
            """) { row in
            guard let url = row.text(0).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
            return HistoryEntry(url: url, title: row.text(1), faviconURL: nil, lastVisit: Date(timeIntervalSince1970: row.double(3) / 1_000_000),
                                visitCount: max(1, row.int(2)))
        }
    }

    // MARK: SQLite

    struct Row {
        let statement: OpaquePointer?
        func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
    }

    /// Runs a query on a copy of a database (browsers keep theirs locked while running).
    static func query<T>(copyOf source: URL, sql: String, map: (Row) -> T?) -> [T] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { return [] }
        let temp = fm.temporaryDirectory.appending(path: "bezier-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: temp) }
        let name = source.lastPathComponent
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-journal"] where fm.fileExists(atPath: source.path(percentEncoded: false) + suffix) {
                try fm.copyItem(atPath: source.path(percentEncoded: false) + suffix, toPath: temp.appending(path: name + suffix).path(percentEncoded: false))
            }
        } catch { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appending(path: name).path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = map(Row(statement: statement)) { result.append(value) }
        }
        return result
    }
}

// MARK: - Applying an import

public struct BrowserImportSummary: Sendable, Equatable {
    public var bookmarks = 0
    public var historyEntries = 0
    public var passwords = 0
    public var passwordsFailed = 0
    public init() {}
}

extension BrowserModel {
    /// Bookmarks go into one collapsed folder ("From Chrome") at the top of the Space's pinned
    /// section, skipping pages already pinned there.
    @discardableResult
    public func applyBookmarks(_ nodes: [ArcImport.Node], from source: ImportSource, into space: Space) -> Int {
        var known = Set(space.allPinnedTabs.compactMap { $0.url?.absoluteString })
        var added = 0
        func convert(_ nodes: [ArcImport.Node]) -> [SidebarNode] {
            nodes.compactMap { node in
                switch node {
                case .tab(let tab):
                    guard known.insert(tab.url.absoluteString).inserted else { return nil }
                    added += 1
                    return .tab(BrowserTab(url: tab.url, title: tab.title, pinnedURL: tab.url))
                case .folder(let title, let children):
                    let converted = convert(children)
                    return converted.isEmpty ? nil : .folder(Folder(title: title, isExpanded: false, children: converted))
                }
            }
        }
        let children = convert(nodes)
        guard !children.isEmpty else { return 0 }
        space.pinned.insert(.folder(Folder(title: "From \(source.name)", isExpanded: false, children: children)), at: 0)
        didChange()
        return added
    }
}
