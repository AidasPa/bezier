import Foundation
import Testing
@testable import BezierCore

struct SiteSearchTests {
    @Test(arguments: [("you", "YouTube"), ("yt", "YouTube"), ("youtube.com", "YouTube"), ("wiki", "Wikipedia"),
                      ("gh", "GitHub"), ("git", "GitHub"), ("maps", "Google Maps"), ("www.reddit.com", "Reddit")])
    func picksSites(typed: String, expected: String) {
        #expect(SiteSearch.match(typed)?.name == expected)
    }

    @Test(arguments: ["y", "zz", "you tube", "", "qqqq"])
    func ignoresOthers(typed: String) {
        #expect(SiteSearch.match(typed) == nil)
    }

    @Test func buildsSearchURLsEvenForAddresses() {
        let youtube = SiteSearch.match("yt")!
        #expect(youtube.url(for: "lo-fi beats").absoluteString == "https://www.youtube.com/results?search_query=lo-fi%20beats")
        #expect(youtube.url(for: "swift.org").absoluteString == "https://www.youtube.com/results?search_query=swift.org")
        #expect(SiteSearch.match("maps")!.url(for: "a/b & c").absoluteString == "https://www.google.com/maps/search/a%2Fb%20%26%20c")
    }
}

struct LinkRouteTests {
    @Test func routesBySiteAndSubdomain() {
        let work = UUID(), design = UUID()
        let routes = [LinkRoute(site: "google.com", spaceID: work), LinkRoute(site: "https://www.figma.com/files", spaceID: design),
                      LinkRoute(site: "*.docs.google.com", spaceID: design)]
        #expect(LinkRoute.route(for: URL(string: "https://mail.google.com/x")!, in: routes)?.spaceID == work)
        #expect(LinkRoute.route(for: URL(string: "https://docs.google.com/d/1")!, in: routes)?.spaceID == design)
        #expect(LinkRoute.route(for: URL(string: "https://figma.com/file/1")!, in: routes)?.spaceID == design)
        #expect(LinkRoute.route(for: URL(string: "https://example.com")!, in: routes) == nil)
    }
}
