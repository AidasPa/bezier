import Foundation
import Testing
@testable import BezierCore

@MainActor
struct BoostTests {
    @Test func matchesTheDomainAndItsSubdomains() {
        let boost = Boost(domain: "example.com")
        #expect(boost.matches(URL(string: "https://example.com/a")))
        #expect(boost.matches(URL(string: "https://docs.example.com")))
        #expect(!boost.matches(URL(string: "https://notexample.com")))
        #expect(Boost.domain(for: URL(string: "https://www.Example.com/x")) == "example.com")
    }

    @Test func buildsOneStylesheet() {
        var boost = Boost(domain: "example.com")
        #expect(boost.isEmpty)
        boost.hue = 90
        boost.zapped = ["#ad", "div.banner"]
        boost.font = "Georgia"
        let css = boost.stylesheet
        #expect(css.contains("hue-rotate(90deg)"))
        #expect(css.contains("#ad,\ndiv.banner { display: none !important; }"))
        #expect(css.contains("font-family: \"Georgia\""))
        #expect(!boost.isEmpty)
    }

    @Test func picksTheMostSpecificBoost() {
        let store = BoostStore(directory: nil)
        store.save(Boost(domain: "example.com"))
        var docs = Boost(domain: "docs.example.com")
        docs.css = "body { color: red }"
        store.save(docs)
        #expect(store.boost(for: URL(string: "https://docs.example.com/x"))?.domain == "docs.example.com")
        #expect(store.boost(for: URL(string: "https://www.example.com"))?.domain == "example.com")
        #expect(store.boost(for: URL(string: "https://example.org")) == nil)
    }
}
