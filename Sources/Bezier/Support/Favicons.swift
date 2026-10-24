import AppKit
import SwiftUI

/// In-memory + on-disk favicon cache. Favicons come from the page itself (the engine reports
/// `<link rel=icon>`) or `/favicon.ico`; no third-party favicon service sees your hosts.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    private var memory: [URL: NSImage] = [:]
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private let directory: URL = {
        let dir = URL.cachesDirectory.appending(path: "Bezier/Favicons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func cached(_ url: URL) -> NSImage? { memory[url] }

    func image(for url: URL) async -> NSImage? {
        if let image = memory[url] { return image }
        if let task = inflight[url] { return await task.value }
        let file = directory.appending(path: String(url.absoluteString.hashValue, radix: 36))
        let task = Task<NSImage?, Never> {
            if let data = try? Data(contentsOf: file), let image = NSImage(data: data) { return image }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = NSImage(data: data), image.isValid else { return nil }
            try? data.write(to: file)
            return image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        memory[url] = image
        return image
    }

    static func fallbackURL(for pageURL: URL?) -> URL? {
        guard let pageURL, let scheme = pageURL.scheme, scheme.hasPrefix("http"), let host = pageURL.host() else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}

struct FaviconView: View {
    let url: URL?
    let pageURL: URL?
    let title: String
    var size: CGFloat = 16

    @State private var image: NSImage?

    private var source: URL? { url ?? FaviconStore.fallbackURL(for: pageURL) }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                // Letter tile while loading or when the site has no icon.
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(Text(String(title.prefix(1)).uppercased())
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: source) {
            guard let source else { image = nil; return }
            image = FaviconStore.shared.cached(source)
            if image == nil { image = await FaviconStore.shared.image(for: source) }
        }
    }
}
