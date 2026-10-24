import Foundation
import SQLite3
import Testing
@testable import BezierCore

@MainActor
struct BrowserImporterTests {
    private func titles(_ nodes: [ArcImport.Node]) -> [String] {
        nodes.flatMap { node -> [String] in
            switch node {
            case .tab(let tab): [tab.title ?? tab.url.absoluteString]
            case .folder(let title, let children): ["[\(title)]"] + titles(children)
            }
        }
    }

    @Test func parsesChromeBookmarks() throws {
        let json = """
        {"roots": {"bookmark_bar": {"children": [
            {"type": "url", "name": "Swift", "url": "https://swift.org"},
            {"type": "folder", "name": "Dev", "children": [{"type": "url", "name": "GitHub", "url": "https://github.com"},
                                                         {"type": "url", "name": "Local", "url": "chrome://settings"}]}]},
          "other": {"children": []}, "synced": {"children": [{"type": "url", "name": "Phone", "url": "https://example.com"}]}}}
        """
        let nodes = BrowserImporter.parseChromiumBookmarks(Data(json.utf8))
        #expect(titles(nodes) == ["[Bookmarks Bar]", "Swift", "[Dev]", "GitHub", "[Mobile Bookmarks]", "Phone"])
    }

    @Test func parsesSafariBookmarks() throws {
        let plist: [String: Any] = ["Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.com", "URIDictionary": ["title": "Apple"]]]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.com"]]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksMenu", "Children": []],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(titles(BrowserImporter.parseSafariBookmarks(data)) == ["[Favorites Bar]", "Apple"])
    }

    @Test func readsFirefoxBookmarksAndHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let places = dir.appending(path: "places.sqlite")
        var db: OpaquePointer?
        sqlite3_open(places.path(percentEncoded: false), &db)
        sqlite3_exec(db, """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_date INTEGER, hidden INTEGER DEFAULT 0);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
            INSERT INTO moz_places VALUES (1, 'https://mozilla.org', 'Mozilla', 3, 1790000000000000, 0), (2, 'https://mdn.dev', 'MDN', 1, NULL, 0);
            INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________'), (2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____'),
              (3, 1, 1, 2, 0, 'Mozilla', 'a'), (4, 2, NULL, 2, 1, 'Docs', 'b'), (5, 1, 2, 4, 0, 'MDN', 'c');
            """, nil, nil, nil)
        sqlite3_close(db)
        #expect(titles(BrowserImporter.readFirefoxBookmarks(places)) == ["[Bookmarks Toolbar]", "Mozilla", "[Docs]", "MDN"])
        let history = BrowserImporter.readFirefoxHistory(places)
        #expect(history.map(\.url.absoluteString) == ["https://mozilla.org"])
        #expect(history.first?.visitCount == 3)
    }

    @Test func bookmarksLandInOneFolder() {
        let space = Space(title: "Test", theme: .neutral)
        let model = BrowserModel(spaces: [space])
        let nodes: [ArcImport.Node] = [.folder(title: "Bookmarks Bar", children: [
            .tab(.init(url: URL(string: "https://a.com")!, title: "A", customTitle: nil, lastActiveAt: nil))])]
        #expect(model.applyBookmarks(nodes, from: .chrome, into: space) == 1)
        #expect(model.applyBookmarks(nodes, from: .chrome, into: space) == 0)             // already pinned
        guard case .folder(let folder)? = space.pinned.first else { Issue.record("no folder"); return }
        #expect(folder.title == "From Google Chrome")
    }
}
