import Foundation
import Testing
@testable import BezierCore

struct TimeZoneQueryTests {
    /// 2026-10-23 12:00 UTC: Vilnius is on EEST (+3), US on DST, London on BST, Berlin on CEST.
    let now = Date(timeIntervalSince1970: 1_792_756_800)
    let local = TimeZone(identifier: "Europe/Vilnius")!

    private func hm(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    @Test(arguments: [
        ("4pm utc", "19:00"),
        ("4 PM UTC", "19:00"),
        ("16:00 utc", "19:00"),
        ("utc 4pm", "19:00"),
        ("4:30pm new york", "23:30"),
        ("noon gmt+2", "13:00"),
        ("3pm in london", "17:00"),
        ("9am pst", "19:00"),
        ("4pm tokyo time", "10:00"),
    ])
    func convertsToLocal(query: String, expected: String) throws {
        let result = try #require(TimeZoneQuery.parse(query, now: now, local: local))
        #expect(result.target == local)
        #expect(hm(result.instant, in: result.target) == expected)
    }

    @Test func convertsBetweenTwoZones() throws {
        let result = try #require(TimeZoneQuery.parse("9am pst to cet", now: now, local: local))
        #expect(result.target.identifier == "Europe/Berlin")
        #expect(hm(result.instant, in: result.target) == "18:00")
    }

    @Test func localToRemote() throws {
        let result = try #require(TimeZoneQuery.parse("10am to tokyo", now: now, local: local))
        #expect(result.source == local)
        #expect(hm(result.instant, in: result.target) == "16:00")
    }

    @Test(arguments: ["time in tokyo", "what time is it in tokyo?", "tokyo time"])
    func currentTimeElsewhere(query: String) throws {
        let result = try #require(TimeZoneQuery.parse(query, now: now, local: local))
        #expect(result.isNow)
        #expect(result.target.identifier == "Asia/Tokyo")
        #expect(hm(result.instant, in: result.target) == "21:00")
    }

    @Test(arguments: ["hello world", "4pm", "github.com", "est", "16 utc pizza", "100 usd", "pm utc", "13pm utc"])
    func ignoresNonTimeQueries(query: String) {
        #expect(TimeZoneQuery.parse(query, now: now, local: local) == nil)
    }
}
