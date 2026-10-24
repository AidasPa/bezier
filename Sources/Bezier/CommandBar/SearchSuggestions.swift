import BezierCore
import Foundation

/// Fetches search-engine suggestions as you type. Each keystroke cancels the previous request;
/// recent answers are cached so backspacing is instant.
@MainActor
final class SearchSuggestions {
    private var cache: [String: [String]] = [:]
    private var task: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    func cached(_ query: String, engine: SearchEngine) -> [String]? {
        cache[engine.rawValue + "\u{1}" + query.lowercased()]
    }

    func fetch(_ query: String, engine: SearchEngine, completion: @escaping @MainActor ([String]) -> Void) {
        task?.cancel()
        let key = engine.rawValue + "\u{1}" + query.lowercased()
        if let hit = cache[key] { completion(hit); return }
        guard let url = engine.suggestURL(for: query) else { return }
        task = Task { [session] in
            guard let (data, _) = try? await session.data(from: url), !Task.isCancelled else { return }
            let suggestions = SearchEngine.parseSuggestions(data)
            self.cache[key] = suggestions
            if self.cache.count > 300 { self.cache.removeAll() }
            completion(suggestions)
        }
    }

    func cancel() { task?.cancel() }
}
