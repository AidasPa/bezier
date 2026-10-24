import BezierEngine
import Foundation
import WebKit

/// Bridges WKDownload to the engine-agnostic `DownloadObserver`.
@MainActor
final class WebKitDownloads: NSObject, WKDownloadDelegate {
    private unowned let engine: WebKitEngine
    private var ids: [ObjectIdentifier: UUID] = [:]
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    init(engine: WebKitEngine) {
        self.engine = engine
    }

    func track(_ download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let directory = engine.downloadDirectory
        let destination = DownloadPaths.unique(for: suggestedFilename, in: directory)
        let id = UUID()
        ids[ObjectIdentifier(download)] = id
        engine.downloadObserver?.downloadDidStart(id: id, sourceURL: download.originalRequest?.url,
                                                  filename: destination.lastPathComponent, destination: destination,
                                                  cancel: { download.cancel { _ in } })
        progressObservations[id] = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            MainActor.assumeIsolated { self?.engine.downloadObserver?.downloadDidProgress(id: id, received: received, total: total) }
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = ids.removeValue(forKey: ObjectIdentifier(download)) else { return }
        progressObservations[id] = nil
        engine.downloadObserver?.downloadDidFinish(id: id)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let id = ids.removeValue(forKey: ObjectIdentifier(download)) else { return }
        progressObservations[id] = nil
        let cancelled = (error as? URLError)?.code == .cancelled || (error as NSError).code == NSURLErrorCancelled
        engine.downloadObserver?.downloadDidFail(id: id, cancelled: cancelled)
    }
}

enum DownloadPaths {
    /// `name.ext`, `name 2.ext`, … so downloads never overwrite each other.
    static func unique(for filename: String, in directory: URL) -> URL {
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = directory.appending(path: safe)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
