import Foundation

/// Arc's Developer Mode: on automatically for local development servers, toggleable per site.
public enum DeveloperMode {
    /// localhost, *.localhost, 127.0.0.0/8, 0.0.0.0 and ::1.
    public static func isLocal(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme, scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "0.0.0.0" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// The key a per-site override is stored under ("localhost:3000" keeps ports apart).
    public static func siteKey(_ url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Default unless the user flipped it for this site.
    public static func isEnabled(for url: URL?, overrides: [String: Bool]) -> Bool {
        guard let key = siteKey(url) else { return false }
        if let override = overrides[key] { return override }
        return isLocal(url)
    }
}
