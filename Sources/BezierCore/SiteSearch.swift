import Foundation

/// Tab to search: type the start of a site's name in the Command Bar, press Tab, and what you
/// type next searches that site.
public struct SiteSearch: Identifiable, Sendable, Equatable {
    public let name: String
    /// For the favicon.
    public let host: String
    /// Words that pick the site; the name is always one of them.
    public let keywords: [String]
    /// `%s` is replaced with the percent-encoded query.
    public let template: String

    public var id: String { host }

    public init(name: String, host: String, keywords: [String] = [], template: String) {
        self.name = name
        self.host = host
        self.keywords = [name.lowercased()] + keywords
        self.template = template
    }

    /// Always a search, even for text that looks like an address.
    public func url(for query: String) -> URL {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#/"))) ?? text
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded)) ?? URL(string: "https://\(host)")!
    }

    /// The site picked by what's typed: a keyword or name starting with it (at least two
    /// characters, a whole keyword like "yt" or "gh" for short ones), or the site's host.
    public static func match(_ text: String, in sites: [SiteSearch] = builtIn) -> SiteSearch? {
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard typed.count >= 2, !typed.contains(" ") else { return nil }
        let bare = typed.replacing(/^(https?:\/\/)?(www\.)?/, with: "")
        if let exact = sites.first(where: { $0.keywords.contains(bare) || $0.host == bare }) { return exact }
        guard bare.count >= 3 else { return nil }
        return sites.first { site in site.keywords.contains { $0.hasPrefix(bare) } || site.host.hasPrefix(bare) }
    }

    public static let builtIn: [SiteSearch] = [
        SiteSearch(name: "YouTube", host: "youtube.com", keywords: ["yt"], template: "https://www.youtube.com/results?search_query=%s"),
        SiteSearch(name: "Google", host: "google.com", template: "https://www.google.com/search?q=%s"),
        SiteSearch(name: "Google Maps", host: "maps.google.com", keywords: ["maps", "map"], template: "https://www.google.com/maps/search/%s"),
        SiteSearch(name: "Google Images", host: "images.google.com", keywords: ["images", "img"], template: "https://www.google.com/search?tbm=isch&q=%s"),
        SiteSearch(name: "Google Translate", host: "translate.google.com", keywords: ["translate"], template: "https://translate.google.com/?text=%s"),
        SiteSearch(name: "Wikipedia", host: "wikipedia.org", keywords: ["wiki", "wp"], template: "https://en.wikipedia.org/w/index.php?search=%s"),
        SiteSearch(name: "GitHub", host: "github.com", keywords: ["gh"], template: "https://github.com/search?q=%s"),
        SiteSearch(name: "Stack Overflow", host: "stackoverflow.com", keywords: ["so", "stackoverflow"], template: "https://stackoverflow.com/search?q=%s"),
        SiteSearch(name: "MDN", host: "developer.mozilla.org", keywords: ["mozilla"], template: "https://developer.mozilla.org/search?q=%s"),
        SiteSearch(name: "Apple Developer", host: "developer.apple.com", keywords: ["apple developer", "swift"], template: "https://developer.apple.com/search/?q=%s"),
        SiteSearch(name: "npm", host: "npmjs.com", template: "https://www.npmjs.com/search?q=%s"),
        SiteSearch(name: "Hacker News", host: "news.ycombinator.com", keywords: ["hn"], template: "https://hn.algolia.com/?q=%s"),
        SiteSearch(name: "Reddit", host: "reddit.com", template: "https://www.reddit.com/search/?q=%s"),
        SiteSearch(name: "X", host: "x.com", keywords: ["twitter"], template: "https://x.com/search?q=%s"),
        SiteSearch(name: "Amazon", host: "amazon.com", template: "https://www.amazon.com/s?k=%s"),
        SiteSearch(name: "eBay", host: "ebay.com", template: "https://www.ebay.com/sch/i.html?_nkw=%s"),
        SiteSearch(name: "IMDb", host: "imdb.com", template: "https://www.imdb.com/find/?q=%s"),
        SiteSearch(name: "Spotify", host: "open.spotify.com", template: "https://open.spotify.com/search/%s"),
        SiteSearch(name: "Netflix", host: "netflix.com", template: "https://www.netflix.com/search?q=%s"),
        SiteSearch(name: "Twitch", host: "twitch.tv", template: "https://www.twitch.tv/search?term=%s"),
        SiteSearch(name: "Pinterest", host: "pinterest.com", template: "https://www.pinterest.com/search/pins/?q=%s"),
        SiteSearch(name: "LinkedIn", host: "linkedin.com", template: "https://www.linkedin.com/search/results/all/?keywords=%s"),
        SiteSearch(name: "Claude", host: "claude.ai", template: "https://claude.ai/new?q=%s"),
        SiteSearch(name: "ChatGPT", host: "chatgpt.com", keywords: ["gpt"], template: "https://chatgpt.com/?q=%s"),
        SiteSearch(name: "Perplexity", host: "perplexity.ai", template: "https://www.perplexity.ai/search?q=%s"),
        SiteSearch(name: "Wolfram Alpha", host: "wolframalpha.com", keywords: ["wolfram"], template: "https://www.wolframalpha.com/input?i=%s"),
        SiteSearch(name: "DuckDuckGo", host: "duckduckgo.com", keywords: ["ddg"], template: "https://duckduckgo.com/?q=%s"),
        SiteSearch(name: "Bing", host: "bing.com", template: "https://www.bing.com/search?q=%s"),
    ]
}
