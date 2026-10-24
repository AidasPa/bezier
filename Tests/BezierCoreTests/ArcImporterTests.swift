import Foundation
import Testing
@testable import BezierCore

/// Fixture in Arc's StorableSidebar.json shape (alternating key/value arrays, enum objects).
private let fixture = """
{"sidebar":{"containers":[
  {"littleBrowser":{"_0":"lb"}}, {"spaces":[],"items":[],"topAppsContainerIDs":[]},
  {"global":{}},
  {"spaces":[
     "S1",{"id":"S1","title":"Work","customInfo":{"iconType":{"emoji_v2":"💼"}},"profile":{"default":true},
           "containerIDs":["unpinned","U1","pinned","P1"]},
     "S2",{"id":"S2","title":"Fun","customInfo":{"iconType":{"icon":"star.fill"}},"profile":{"default":true},
           "containerIDs":["pinned","P2","unpinned","U2"]}],
   "items":[
     "P1",{"id":"P1","childrenIds":["F1","T1"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"S1"}}}}},
     "F1",{"id":"F1","title":"Docs","childrenIds":["T2"],"data":{"list":{}}},
     "T1",{"id":"T1","title":"My Linear","childrenIds":[],"data":{"tab":{"savedURL":"https://linear.app","savedTitle":"Linear","timeLastActiveAt":782000000}}},
     "T2",{"id":"T2","title":null,"childrenIds":[],"data":{"tab":{"savedURL":"https://docs.swift.org","savedTitle":"Swift Docs"}}},
     "U1",{"id":"U1","childrenIds":["T3"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"S1"}}}}},
     "T3",{"id":"T3","childrenIds":[],"data":{"tab":{"savedURL":"https://news.ycombinator.com","savedTitle":"HN"}}},
     "P2",{"id":"P2","childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"S2"}}}}},
     "U2",{"id":"U2","childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"S2"}}}}},
     "TA",{"id":"TA","childrenIds":["T4"],"data":{"itemContainer":{"containerType":{"topApps":{"_0":{"default":true}}}}}},
     "T4",{"id":"T4","childrenIds":[],"data":{"tab":{"savedURL":"https://mail.google.com","savedTitle":"Gmail"}}}],
   "topAppsContainerIDs":[{"default":true},"TA"]}
]}}
"""

@MainActor
struct ArcImporterTests {
    @Test func parsesSpacesTreeTodayAndFavorites() throws {
        let arc = try ArcImporter.parseSidebar(Data(fixture.utf8))
        #expect(arc.spaces.map(\.title) == ["Work", "Fun"])
        #expect(arc.spaces[0].icon == "💼")
        #expect(arc.spaces[1].icon == nil) // SF Symbol names aren't emoji
        guard case .folder(let title, let children)? = arc.spaces[0].pinned.first else { Issue.record("no folder"); return }
        #expect(title == "Docs")
        #expect(children == [.tab(.init(url: URL(string: "https://docs.swift.org")!, title: "Swift Docs", customTitle: nil, lastActiveAt: nil))])
        if case .tab(let linear)? = arc.spaces[0].pinned.last {
            #expect(linear.customTitle == "My Linear")
        } else { Issue.record("no pinned tab") }
        #expect(arc.spaces[0].today.map(\.url.host) == ["news.ycombinator.com"])
        #expect(arc.favorites.map(\.title) == ["Gmail"])
        #expect(arc.pinnedTabCount == 2 && arc.folderCount == 1 && arc.todayTabCount == 1)
    }

    @Test func applyingTwiceDoesNotDuplicate() throws {
        let arc = try ArcImporter.parseSidebar(Data(fixture.utf8))
        let model = BrowserModel(spaces: [Space(title: "work", theme: .neutral)])
        let first = model.apply(arc, options: ArcImportOptions(), history: nil)
        #expect(first.spacesMerged == 1 && first.spacesAdded == 1)
        #expect(first.pinnedTabs == 2 && first.folders == 1 && first.todayTabs == 1 && first.favorites == 1)
        let second = model.apply(arc, options: ArcImportOptions(), history: nil)
        #expect(second.pinnedTabs == 0 && second.todayTabs == 0 && second.favorites == 0)
        #expect(model.spaces.count == 2)
        #expect(model.spaces[1].theme.isNeutral)
    }

    @Test func rejectsUnknownFiles() {
        #expect(throws: (any Error).self) { try ArcImporter.parseSidebar(Data("{}".utf8)) }
    }

    @Test func historyMergeKeepsNewestAndCounts() {
        let history = HistoryStore(directory: nil)
        let url = URL(string: "https://a.com")!
        history.recordVisit(url, title: "A", faviconURL: nil, at: Date(timeIntervalSince1970: 100))
        let added = history.merge([
            HistoryEntry(url: url, title: nil, faviconURL: nil, lastVisit: Date(timeIntervalSince1970: 200), visitCount: 9),
            HistoryEntry(url: URL(string: "https://b.com")!, title: "B", faviconURL: nil, lastVisit: .now, visitCount: 1),
        ])
        #expect(added == 1)
        #expect(history.entries[url.absoluteString]?.visitCount == 9)
        #expect(history.entries[url.absoluteString]?.title == "A")
    }
}

/// Manual check against the local Arc install: `BEZIER_ARC_DRYRUN=1 swift test --filter ArcDryRun`.
/// Prints counts only, never titles or URLs.
struct ArcDryRun {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEZIER_ARC_DRYRUN"] == "1"))
    func countsFromInstalledArc() throws {
        let arc = try ArcImporter.load(includeHistory: true)
        print("[arc-dry-run] spaces=\(arc.spaces.count) pinnedTabs=\(arc.pinnedTabCount) folders=\(arc.folderCount) today=\(arc.todayTabCount) favorites=\(arc.favorites.count) history=\(arc.history.count) iconsFound=\(arc.spaces.filter { $0.icon != nil }.count)")
        #expect(!arc.spaces.isEmpty)
    }
}
