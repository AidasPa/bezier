import AppKit
import BezierCore
import BezierEngine

/// Engine download events → the Library's download list, plus a toast in the active window.
@MainActor
final class DownloadsCoordinator: DownloadObserver {
    let store: DownloadsStore
    var toast: ((String, String) -> Void)?

    init(store: DownloadsStore) {
        self.store = store
    }

    func downloadDidStart(id: UUID, sourceURL: URL?, filename: String, destination: URL, cancel: @escaping @MainActor () -> Void) {
        let item = DownloadItem(id: id, sourceURL: sourceURL, filename: filename, fileURL: destination)
        item.cancelHandler = cancel
        store.add(item)
        toast?("Downloading \(filename)", "arrow.down.circle")
    }

    func downloadDidProgress(id: UUID, received: Int64, total: Int64) {
        guard let item = item(id) else { return }
        item.receivedBytes = received
        item.totalBytes = max(total, received)
    }

    func downloadDidFinish(id: UUID) {
        guard let item = item(id) else { return }
        item.state = .completed
        item.receivedBytes = max(item.receivedBytes, item.totalBytes)
        store.save()
        toast?("Downloaded \(item.filename)", "checkmark.circle")
    }

    func downloadDidFail(id: UUID, cancelled: Bool) {
        guard let item = item(id) else { return }
        item.state = cancelled ? .cancelled : .failed
        store.save()
        if !cancelled { toast?("Download failed: \(item.filename)", "exclamationmark.triangle") }
    }

    private func item(_ id: UUID) -> DownloadItem? { store.items.first { $0.id == id } }
}
