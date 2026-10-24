import Foundation

/// Search providers for the Command Bar. All suggestion endpoints speak the OpenSearch JSON
/// format: `["query", ["suggestion", …]]`.
public enum SearchEngine: String, CaseIterable, Codable, Sendable, Identifiable {
    case google, duckDuckGo, bing, brave, ecosia, kagi

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        }
    }

    /// `%s` is replaced with the percent-encoded query.
    public var searchTemplate: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .duckDuckGo: "https://duckduckgo.com/?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        }
    }

    public var suggestTemplate: String? {
        switch self {
        case .google: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
        case .duckDuckGo: "https://duckduckgo.com/ac/?q=%s&type=list"
        case .bing: "https://api.bing.com/osjson.aspx?query=%s"
        case .brave: "https://search.brave.com/api/suggest?q=%s"
        case .ecosia: "https://ac.ecosia.org/autocomplete?q=%s&type=list"
        case .kagi: nil // requires a signed-in session
        }
    }

    public func searchURL(for query: String) -> URL {
        URLInput.url(from: query, searchTemplate: searchTemplate)
    }

    public func suggestURL(for query: String) -> URL? {
        guard let template = suggestTemplate,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// Parses an OpenSearch suggestions response.
    public static func parseSuggestions(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count >= 2,
              let list = json[1] as? [String] else { return [] }
        return list
    }
}
