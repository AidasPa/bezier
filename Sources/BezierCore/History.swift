import Foundation
import Observation

public struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public init(url: URL, title: String?, faviconURL: URL?, lastVisit: Date, visitCount: Int) {
        self.url = url; self.title = title; self.faviconURL = faviconURL; self.lastVisit = lastVisit; self.visitCount = visitCount
    }

    public var id: String { url.absoluteString }
    public var url: URL
    public var title: String?
    public var faviconURL: URL?
    public var lastVisit: Date
    public var visitCount: Int
}

/// Browsing history: one entry per URL, ranked by frecency for the Command Bar.
/// JSON-backed for now; swaps to SQLite when it outgrows that.
@MainActor
@Observable
public final class HistoryStore {
    public private(set) var entries: [String: HistoryEntry] = [:]
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored public var limit = 20_000

    public init(directory: URL? = BrowserStore.defaultDirectory) {
        fileURL = directory?.appending(path: "History.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder.store.decode([HistoryEntry].self, from: data) {
            entries = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Records a visit. Fragments are ignored so in-page anchors don't count as new pages.
    public func recordVisit(_ url: URL, title: String?, faviconURL: URL?, at date: Date = .now) {
        guard let key = Self.normalize(url) else { return }
        if var entry = entries[key.absoluteString] {
            if date.timeIntervalSince(entry.lastVisit) > 30 { entry.visitCount += 1 }
            entry.lastVisit = date
            if let title { entry.title = title }
            if let faviconURL { entry.faviconURL = faviconURL }
            entries[key.absoluteString] = entry
        } else {
            entries[key.absoluteString] = HistoryEntry(url: key, title: title, faviconURL: faviconURL, lastVisit: date, visitCount: 1)
            trimIfNeeded()
        }
        scheduleSave()
    }

    /// Updates title/favicon for a page already in history without counting a visit.
    public func update(_ url: URL, title: String?, faviconURL: URL?) {
        guard let key = Self.normalize(url)?.absoluteString, var entry = entries[key] else { return }
        let changed = (title != nil && entry.title != title) || (faviconURL != nil && entry.faviconURL != faviconURL)
        guard changed else { return }
        if let title { entry.title = title }
        if let faviconURL { entry.faviconURL = faviconURL }
        entries[key] = entry
        scheduleSave()
    }

    /// Inserts or overwrites one entry as-is (imports).
    public func replace(_ entry: HistoryEntry) {
        entries[entry.id] = entry
        scheduleSave()
    }

    public func remove(_ entry: HistoryEntry) {
        entries[entry.id] = nil
        scheduleSave()
    }

    public func clear() {
        entries = [:]
        scheduleSave()
    }

    /// Most recent first.
    public var recent: [HistoryEntry] {
        entries.values.sorted { $0.lastVisit > $1.lastVisit }
    }

    /// Matches every query token against title words (prefix) or the URL (substring), ranked
    /// by match quality and frecency.
    public func search(_ query: String, limit: Int = 8, now: Date = .now) -> [(entry: HistoryEntry, score: Int)] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        var results: [(HistoryEntry, Int)] = []
        for entry in entries.values {
            let title = (entry.title ?? "").lowercased()
            let url = entry.url.absoluteString.lowercased()
                .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            let host = url.hasPrefix("www.") ? String(url.dropFirst(4)) : url
            let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            var quality = 0
            for token in tokens {
                if host.hasPrefix(token) { quality += 30 }
                else if words.contains(where: { $0.hasPrefix(token) }) { quality += 22 }
                else if url.contains(token) || title.contains(token) { quality += 10 }
                else { quality = -1; break }
            }
            guard quality > 0 else { continue }
            let ageDays = now.timeIntervalSince(entry.lastVisit) / 86_400
            let recency = ageDays < 1 ? 12 : ageDays < 7 ? 8 : ageDays < 30 ? 4 : 0
            let frequency = min(12, Int(log2(Double(entry.visitCount) + 1) * 4))
            results.append((entry, quality / tokens.count + recency + frequency))
        }
        return results.sorted { $0.1 > $1.1 }.prefix(limit).map { (entry: $0.0, score: $0.1) }
    }

    static func normalize(_ url: URL) -> URL? {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" || scheme == "file" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url
    }

    private func trimIfNeeded() {
        guard entries.count > limit else { return }
        for entry in entries.values.sorted(by: { $0.lastVisit < $1.lastVisit }).prefix(entries.count - limit) {
            entries[entry.id] = nil
        }
    }

    private func scheduleSave() {
        guard let fileURL else { return }
        pendingSave?.cancel()
        pendingSave = Task { [entries] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let data = try? JSONEncoder.store.encode(Array(entries.values))
            await Task.detached(priority: .utility) { try? data?.write(to: fileURL, options: .atomic) }.value
        }
    }

    public func saveNow() {
        guard let fileURL else { return }
        pendingSave?.cancel()
        try? JSONEncoder.store.encode(Array(entries.values)).write(to: fileURL, options: .atomic)
    }
}
