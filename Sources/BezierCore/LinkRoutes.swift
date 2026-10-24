import Foundation

/// Air Traffic Control: links opened from other apps that match a rule go straight to a Space
/// instead of a Mini window.
public struct LinkRoute: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    /// A site such as "figma.com"; also matches its subdomains. A leading "*." is ignored.
    public var site: String
    public var spaceID: UUID

    public init(site: String, spaceID: UUID) {
        self.site = site
        self.spaceID = spaceID
    }

    public var normalizedSite: String {
        var s = site.trimmingCharacters(in: .whitespaces).lowercased()
        s = s.replacing(/^[a-z]+:\/\//, with: "")
        if s.hasPrefix("*.") { s.removeFirst(2) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s.split(separator: "/").first.map(String.init) ?? s
    }

    public func matches(_ url: URL) -> Bool {
        let site = normalizedSite
        guard !site.isEmpty, let host = url.host()?.lowercased() else { return false }
        return host == site || host.hasSuffix("." + site)
    }

    /// The first matching rule, most specific site first.
    public static func route(for url: URL, in routes: [LinkRoute]) -> LinkRoute? {
        routes.filter { $0.matches(url) }.max { $0.normalizedSite.count < $1.normalizedSite.count }
    }
}
