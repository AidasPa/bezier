import Foundation
import Testing
@testable import BezierCore

@MainActor
struct BrowserModelTests {
    private func makeModel() -> (BrowserModel, Space) {
        let space = Space(title: "Test", theme: .lavender)
        return (BrowserModel(spaces: [space]), space)
    }

    @Test func newTabsGoToTopOfToday() {
        let (model, space) = makeModel()
        let a = model.newTab(url: URL(string: "https://a.com"), in: space)
        let b = model.newTab(url: URL(string: "https://b.com"), in: space)
        #expect(space.today.map(\.id) == [b.id, a.id])
    }

    @Test func archiveAndRestoreRoundTrips() {
        let (model, space) = makeModel()
        let tab = model.newTab(url: URL(string: "https://a.com"), in: space)
        model.archive(tab)
        #expect(space.today.isEmpty)
        #expect(model.archive.first?.id == tab.id)
        let restored = model.restoreLastArchived(fallback: space)
        #expect(restored?.url == tab.url)
        #expect(space.today.count == 1)
    }

    @Test func pinningMovesTabAndRemembersURL() {
        let (model, space) = makeModel()
        let tab = model.newTab(url: URL(string: "https://a.com/x"), in: space)
        model.togglePin(tab)
        #expect(space.today.isEmpty)
        #expect(space.allPinnedTabs.first === tab)
        #expect(tab.pinnedURL == URL(string: "https://a.com/x"))
        tab.url = URL(string: "https://a.com/y")
        #expect(tab.hasDriftedFromPinnedURL)
        model.togglePin(tab)
        #expect(space.today.first === tab)
        #expect(tab.pinnedURL == nil)
    }

    @Test func autoArchiveSkipsProtectedAndFreshTabs() {
        let (model, space) = makeModel()
        let old = model.newTab(url: URL(string: "https://old.com"), in: space)
        old.lastActiveAt = .now.addingTimeInterval(-13 * 3600)
        let visible = model.newTab(url: URL(string: "https://visible.com"), in: space)
        visible.lastActiveAt = .now.addingTimeInterval(-13 * 3600)
        let fresh = model.newTab(url: URL(string: "https://fresh.com"), in: space)
        model.autoArchive(protected: [visible.id])
        #expect(space.today.map(\.id).sorted() == [visible.id, fresh.id].sorted())
        #expect(model.archive.first?.reason == .auto)
    }

    @Test func snapshotRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = BrowserStore(directory: dir)
        let (model, space) = makeModel()
        model.newFolder(in: space, title: "Docs")
        model.newTab(url: URL(string: "https://a.com"), in: space)
        store.saveNow(model)
        let loaded = store.load()
        #expect(loaded.spaces.first?.title == "Test")
        #expect(loaded.spaces.first?.today.first?.url == URL(string: "https://a.com"))
        if case .folder(let folder)? = loaded.spaces.first?.pinned.first { #expect(folder.title == "Docs") } else { Issue.record("folder lost") }
    }
}

struct URLInputTests {
    @Test(arguments: [
        ("github.com", "https://github.com"),
        ("localhost:3000", "http://localhost:3000"),
        ("https://arc.net/max", "https://arc.net/max"),
        ("192.168.1.1", "http://192.168.1.1"),
    ])
    func directURLs(input: String, expected: String) {
        #expect(URLInput.directURL(input)?.absoluteString == expected)
    }

    @Test(arguments: ["swift concurrency", "hello", "what is 1.5"])
    func searches(input: String) {
        #expect(URLInput.directURL(input) == nil)
        #expect(URLInput.url(from: input).host() == "www.google.com")
    }
}

@MainActor
struct HistoryStoreTests {
    @Test func ranksHostPrefixAndIgnoresFragments() {
        let history = HistoryStore(directory: nil)
        history.recordVisit(URL(string: "https://github.com/apple/swift#readme")!, title: "Swift", faviconURL: nil)
        history.recordVisit(URL(string: "https://example.com/github-tips")!, title: "Tips", faviconURL: nil)
        #expect(history.entries.count == 2)
        let results = history.search("github")
        #expect(results.first?.entry.url.absoluteString == "https://github.com/apple/swift")
        #expect(results.count == 2)
        #expect(history.search("zzz").isEmpty)
    }

    @Test func revisitsBumpCountButNotWithinThirtySeconds() {
        let history = HistoryStore(directory: nil)
        let url = URL(string: "https://a.com")!
        let start = Date.now
        history.recordVisit(url, title: nil, faviconURL: nil, at: start)
        history.recordVisit(url, title: nil, faviconURL: nil, at: start.addingTimeInterval(5))
        history.recordVisit(url, title: "A", faviconURL: nil, at: start.addingTimeInterval(60))
        #expect(history.entries[url.absoluteString]?.visitCount == 2)
        #expect(history.entries[url.absoluteString]?.title == "A")
    }
}

struct SearchEngineTests {
    @Test func parsesOpenSearchSuggestions() {
        let data = Data(#"["dsf",["dsf8","dsf ford","dsfa"]]"#.utf8)
        #expect(SearchEngine.parseSuggestions(data) == ["dsf8", "dsf ford", "dsfa"])
        #expect(SearchEngine.parseSuggestions(Data("nope".utf8)).isEmpty)
    }

    @Test func buildsURLs() {
        #expect(SearchEngine.duckDuckGo.searchURL(for: "swift ui").absoluteString == "https://duckduckgo.com/?q=swift%20ui")
        #expect(SearchEngine.google.suggestURL(for: "a&b")?.absoluteString.contains("q=a%26b") == true)
    }
}

@MainActor
struct SpaceEditingTests {
    @Test func deleteKeepsLastSpaceAndArchivesToday() {
        let a = Space(title: "A", theme: .lavender)
        let b = Space(title: "B", theme: .sky)
        let model = BrowserModel(spaces: [a, b])
        model.newTab(url: URL(string: "https://a.com"), in: a)
        #expect(model.delete(a))
        #expect(model.spaces.map(\.title) == ["B"])
        #expect(model.archive.count == 1)
        #expect(!model.delete(b))
    }

    @Test func themeDecodesWithoutIntensity() throws {
        let json = Data(#"{"colors":[{"r":1,"g":0,"b":0,"a":1}],"appearance":"light","grain":0.5}"#.utf8)
        let theme = try JSONDecoder().decode(SpaceTheme.self, from: json)
        #expect(theme.intensity == 1)
    }
}

struct DeveloperModeTests {
    @Test(arguments: ["http://localhost:3000", "http://app.localhost", "http://127.0.0.1:8080/x", "http://127.4.5.6", "http://0.0.0.0:5173"])
    func localURLsAreDevByDefault(url: String) {
        #expect(DeveloperMode.isEnabled(for: URL(string: url), overrides: [:]))
    }

    @Test(arguments: ["https://github.com", "http://localhost.evil.com", "http://127.0.0.1.nip.io", "file:///tmp/a.html"])
    func remoteURLsAreNot(url: String) {
        #expect(!DeveloperMode.isEnabled(for: URL(string: url), overrides: [:]))
    }

    @Test func overridesWinPerSiteAndPort() {
        let overrides = ["localhost:3000": false, "github.com": true]
        #expect(!DeveloperMode.isEnabled(for: URL(string: "http://localhost:3000/a"), overrides: overrides))
        #expect(DeveloperMode.isEnabled(for: URL(string: "http://localhost:4000"), overrides: overrides))
        #expect(DeveloperMode.isEnabled(for: URL(string: "https://github.com/x"), overrides: overrides))
    }
}

@MainActor
struct TabGroupTests {
    private func setup() -> (BrowserModel, Space, BrowserTab) {
        let space = Space(title: "S", theme: .lavender)
        let model = BrowserModel(spaces: [space])
        let opener = model.newTab(url: URL(string: "https://news.ycombinator.com"), in: space)
        return (model, space, opener)
    }

    @Test func linksFromAPageFormAGroupInOrder() {
        let (model, space, opener) = setup()
        let other = model.newTab(url: URL(string: "https://other.com"), in: space)
        let a = model.openChild(url: URL(string: "https://a.com"), from: opener, in: space)
        let b = model.openChild(url: URL(string: "https://b.com"), from: opener, in: space)
        let fromChild = model.openChild(url: URL(string: "https://c.com"), from: a, in: space)
        #expect(space.groups.count == 1)
        #expect(space.groups[0].title == "news.ycombinator.com")
        #expect(space.today.map(\.id) == [other.id, opener.id, a.id, b.id, fromChild.id])
        #expect(Set([opener, a, b, fromChild].map(\.groupID)) == [space.groups[0].id])
    }

    @Test func groupOfOneDissolves() {
        let (model, space, opener) = setup()
        let child = model.openChild(url: URL(string: "https://a.com"), from: opener, in: space)
        model.archive(child)
        #expect(space.groups.isEmpty)
        #expect(opener.groupID == nil)
    }

    @Test func pinnedOpenerKeepsGroupUntilEmpty() {
        let (model, space, opener) = setup()
        model.togglePin(opener)
        let a = model.openChild(url: URL(string: "https://a.com"), from: opener, in: space)
        #expect(space.groups.count == 1)
        #expect(opener.groupID == nil)
        let b = model.openChild(url: URL(string: "https://b.com"), from: opener, in: space)
        #expect(space.today.map(\.id) == [a.id, b.id])
        model.archive(a)
        #expect(space.groups.count == 1)
        model.archive(b)
        #expect(space.groups.isEmpty)
    }

    @Test func groupsPersist() {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = BrowserStore(directory: dir)
        let (model, space, opener) = setup()
        model.openChild(url: URL(string: "https://a.com"), from: opener, in: space)
        store.saveNow(model)
        let loaded = store.load()
        #expect(loaded.spaces[0].groups.count == 1)
        #expect(loaded.spaces[0].today.allSatisfy { $0.groupID == loaded.spaces[0].groups[0].id })
    }
}

@MainActor
struct DragToSplitAndGroupTests {
    private func setup() -> (BrowserModel, Space, BrowserTab, BrowserTab, BrowserTab) {
        let space = Space(title: "S", theme: .neutral)
        let model = BrowserModel(spaces: [space])
        let c = model.newTab(url: URL(string: "https://c.com"), in: space)
        let b = model.newTab(url: URL(string: "https://b.com"), in: space)
        let a = model.newTab(url: URL(string: "https://a.com"), in: space)
        return (model, space, a, b, c) // today: a, b, c
    }

    @Test func dropOnRightEdgeSplitsSideBySide() {
        let (model, space, a, b, c) = setup()
        model.split(c, onto: a, side: .right, in: space)
        #expect(space.today.map(\.id) == [a.id, c.id, b.id])
        #expect(a.splitID != nil && a.splitID == c.splitID)
        #expect(space.panes(of: a.splitID!).map(\.id) == [a.id, c.id])
        model.split(b, onto: a, side: .left, in: space)
        #expect(space.panes(of: a.splitID!).map(\.id) == [b.id, a.id, c.id])
    }

    @Test func archivingAPaneDissolvesASplitOfTwo() {
        let (model, space, a, b, _) = setup()
        model.split(b, onto: a, side: .right, in: space)
        model.archive(b)
        #expect(a.splitID == nil)
    }

    @Test func dropInMiddleGroupsAndKeepsSplitsTogether() {
        let (model, space, a, b, c) = setup()
        model.split(b, onto: a, side: .right, in: space)
        model.group(c, onto: a, in: space)
        let group = try! #require(space.groups.first)
        #expect([a, b, c].allSatisfy { $0.groupID == group.id })
        #expect(space.today.map(\.id) == [a.id, b.id, c.id])
        #expect(a.splitID == b.splitID && c.splitID == nil)
    }

    @Test func splitsPersist() {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = BrowserStore(directory: dir)
        let (model, space, a, b, _) = setup()
        model.split(b, onto: a, side: .right, in: space)
        store.saveNow(model)
        let loaded = store.load().spaces[0]
        #expect(loaded.today[0].splitID != nil && loaded.today[0].splitID == loaded.today[1].splitID)
    }

    @Test func dividerWidthsPersistAndResetWhenAPaneJoins() {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = BrowserStore(directory: dir)
        let (model, space, a, b, c) = setup()
        model.split(b, onto: a, side: .right, in: space)
        model.resizeSplit(a.splitID!, widths: [0.7, 0.3], in: space)
        store.saveNow(model)
        #expect(store.load().spaces[0].today.prefix(2).map(\.splitWidth) == [0.7, 0.3])
        model.split(c, onto: b, side: .right, in: space)
        #expect(space.panes(of: a.splitID!).allSatisfy { $0.splitWidth == nil })
    }

    @Test func reorderingWithinTodayAndAcrossToPinned() {
        let (model, space, a, b, c) = setup()                      // today: a, b, c
        model.move(c, .before, a.id, in: space)
        #expect(space.today.map(\.id) == [c.id, a.id, b.id])
        model.move(c, .after, b.id, in: space)
        #expect(space.today.map(\.id) == [a.id, b.id, c.id])
        // Onto the pinned section: pinned, remembering its URL; and back to Today unpinned.
        let folder = model.newFolder(in: space)
        let pinned = BrowserTab(url: URL(string: "https://p.com"), pinnedURL: URL(string: "https://p.com"))
        folder.children = [.tab(pinned)]
        model.move(b, .after, pinned.id, in: space)
        #expect(folder.children.map(\.id) == [pinned.id, b.id] && b.pinnedURL == b.url)
        #expect(space.today.map(\.id) == [a.id, c.id])
        model.move(pinned, .before, a.id, in: space)
        #expect(space.today.map(\.id) == [pinned.id, a.id, c.id] && pinned.pinnedURL == nil)
        model.move(c, into: folder, in: space)
        #expect(folder.children.map(\.id) == [b.id, c.id] && c.pinnedURL != nil)
        model.move(a, .before, folder.id, in: space)
        #expect(space.pinned.map(\.id) == [a.id, folder.id])
    }

    @Test func reorderingJoinsTheTargetsGroupAndSkipsSplitRuns() {
        let (model, space, a, b, c) = setup()                      // today: a, b, c
        model.split(b, onto: a, side: .right, in: space)           // [a|b], c
        model.move(c, .before, b.id, in: space)                     // before the split row, not between panes
        #expect(space.today.map(\.id) == [c.id, a.id, b.id] && a.splitID == b.splitID && c.splitID == nil)
        let d = model.newTab(url: URL(string: "https://d.com"), in: space)
        model.group(d, onto: c, in: space)                          // group(c, d), [a|b]
        model.move(a, .after, c.id, in: space)
        #expect(a.groupID == c.groupID && a.splitID == nil && b.splitID == nil)
    }

    @Test func draggingATabOutOfItsGroupPlacesItBesideTheGroup() {
        let (model, space, a, b, c) = setup()
        model.group(b, onto: a, in: space)
        model.group(c, onto: a, in: space)
        model.removeFromGroup(b, below: true, in: space)
        #expect(b.groupID == nil && a.groupID != nil && a.groupID == c.groupID)
        #expect(space.today.map(\.id) == [a.id, c.id, b.id])
        model.removeFromGroup(c, below: false, in: space)
        #expect(space.groups.isEmpty && a.groupID == nil)     // a group of one dissolves
        #expect(space.today.map(\.id) == [c.id, a.id, b.id])
    }
}
