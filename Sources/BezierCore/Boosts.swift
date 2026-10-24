import Foundation
import Observation

/// Arc's Boosts: a site's own colours, font, hidden ("zapped") elements and custom CSS and
/// JavaScript. Applies to the domain and its subdomains.
public struct Boost: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    /// "example.com" (no "www.").
    public var domain: String
    public var isEnabled = true
    /// Page colours: a hue shift in degrees (0 is off); saturation and brightness (1 is unchanged).
    public var hue: Double = 0
    public var saturation: Double = 1
    public var brightness: Double = 1
    /// Light pages turned dark (images flipped back).
    public var invert = false
    public var font: String?
    /// CSS selectors hidden with Zap.
    public var zapped: [String] = []
    public var css = ""
    public var js = ""

    public init(domain: String) {
        self.domain = domain
    }

    /// The site part of a URL: host without "www.".
    public static func domain(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty, url?.scheme?.hasPrefix("http") == true else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public func matches(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Everything the boost changes, as one stylesheet.
    public var stylesheet: String {
        var rules: [String] = []
        var filters: [String] = []
        if invert { filters.append("invert(1) hue-rotate(180deg)") }
        if hue != 0 { filters.append("hue-rotate(\(Int(hue))deg)") }
        if saturation != 1 { filters.append("saturate(\(Self.number(saturation)))") }
        if brightness != 1 { filters.append("brightness(\(Self.number(brightness)))") }
        if !filters.isEmpty {
            rules.append("html { filter: \(filters.joined(separator: " ")) !important; }")
            if invert {
                // Flip media back so photos and video look right on the inverted page.
                rules.append("img, video, picture, canvas, iframe, [style*=\"background-image\"] { filter: invert(1) hue-rotate(180deg) !important; }")
            }
        }
        if let font, !font.isEmpty {
            let family = font.replacingOccurrences(of: "\"", with: "")
            rules.append("body, body *:not(code):not(pre):not(kbd):not(samp):not(i):not([class*=\"icon\"]):not([class*=\"Icon\"]) { font-family: \"\(family)\", system-ui !important; }")
        }
        if !zapped.isEmpty { rules.append(zapped.joined(separator: ",\n") + " { display: none !important; }") }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rules.append(css) }
        return rules.joined(separator: "\n")
    }

    /// Nothing changed from the page as it comes.
    public var isEmpty: Bool { stylesheet.isEmpty && js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func number(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// Boosts, persisted as `Boosts.json` next to the sidebar file.
@MainActor
@Observable
public final class BoostStore {
    public private(set) var boosts: [Boost] = []
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// `directory: nil` keeps everything in memory (tests).
    public init(directory: URL? = BrowserStore.defaultDirectory) {
        fileURL = directory?.appending(path: "Boosts.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Boost].self, from: data) {
            boosts = saved
        }
    }

    /// The boost for a page: the most specific domain that matches.
    public func boost(for url: URL?) -> Boost? {
        boosts.filter { $0.matches(url) }.max { $0.domain.count < $1.domain.count }
    }

    public func save(_ boost: Boost) {
        if let i = boosts.firstIndex(where: { $0.id == boost.id }) { boosts[i] = boost } else { boosts.append(boost) }
        changed()
    }

    public func remove(_ id: UUID) {
        boosts.removeAll { $0.id == id }
        changed()
    }

    private func changed() {
        onChange?()
        guard let fileURL else { return }
        pendingSave?.cancel()
        let snapshot = boosts
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
