import Foundation

/// Turns what the user typed in the Command Bar into a URL to load.
public enum URLInput {
    public static func url(from input: String, searchTemplate: String = "https://www.google.com/search?q=%s") -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = directURL(text) { return url }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: query))!
    }

    /// Returns a URL if `text` is navigable as-is, `nil` if it should be a search.
    public static func directURL(_ text: String) -> URL? {
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        if ["http://", "https://", "file://", "about:", "data:"].contains(where: lower.hasPrefix) {
            return URL(string: text)
        }
        if lower.hasPrefix("localhost") || lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + text)
        }
        // host.tld with a plausible TLD
        let hostPart = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return URL(string: "https://" + text)
    }

    /// "github.com" style display string for the URL pill.
    public static func displayHost(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var host = url.host() else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
