import Foundation
import Observation

/// One web download. In-progress state is live; finished downloads persist so the Library
/// can show them (Arc: "Library downloads = everything downloaded from the web").
@MainActor
@Observable
public final class DownloadItem: Identifiable {
    public enum State: String, Codable, Sendable { case inProgress, completed, failed, cancelled }

    public let id: UUID
    public let sourceURL: URL?
    public var filename: String
    public var fileURL: URL?
    public var state: State
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public let startedAt: Date
    @ObservationIgnored public var cancelHandler: (() -> Void)?

    public init(id: UUID = UUID(), sourceURL: URL?, filename: String, fileURL: URL? = nil, state: State = .inProgress,
                receivedBytes: Int64 = 0, totalBytes: Int64 = 0, startedAt: Date = .now) {
        self.id = id
        self.sourceURL = sourceURL
        self.filename = filename
        self.fileURL = fileURL
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.startedAt = startedAt
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

@MainActor
@Observable
public final class DownloadsStore {
    public private(set) var items: [DownloadItem] = []
    @ObservationIgnored private let fileURL: URL?

    private struct Record: Codable {
        var id: UUID; var sourceURL: URL?; var filename: String; var fileURL: URL?
        var state: DownloadItem.State; var totalBytes: Int64; var startedAt: Date
    }

    public init(directory: URL? = BrowserStore.defaultDirectory) {
        fileURL = directory?.appending(path: "Downloads.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let records = try? JSONDecoder.store.decode([Record].self, from: data) {
            items = records.map {
                DownloadItem(id: $0.id, sourceURL: $0.sourceURL, filename: $0.filename, fileURL: $0.fileURL,
                             state: $0.state == .inProgress ? .failed : $0.state,
                             receivedBytes: $0.totalBytes, totalBytes: $0.totalBytes, startedAt: $0.startedAt)
            }
        }
    }

    public var active: [DownloadItem] { items.filter { $0.state == .inProgress } }

    /// Combined progress of in-flight downloads, for the Library icon's ring.
    public var activeFraction: Double? {
        let active = active
        guard !active.isEmpty else { return nil }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return 0 }
        return Double(active.reduce(Int64(0)) { $0 + $1.receivedBytes }) / Double(total)
    }

    public func add(_ item: DownloadItem) {
        items.insert(item, at: 0)
        save()
    }

    public func remove(_ item: DownloadItem) {
        items.removeAll { $0 === item }
        save()
    }

    public func save() {
        guard let fileURL else { return }
        let records = items.prefix(500).map {
            Record(id: $0.id, sourceURL: $0.sourceURL, filename: $0.filename, fileURL: $0.fileURL,
                   state: $0.state, totalBytes: $0.totalBytes, startedAt: $0.startedAt)
        }
        try? JSONEncoder.store.encode(records).write(to: fileURL, options: .atomic)
    }
}
