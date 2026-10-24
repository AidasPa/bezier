import CryptoKit
import Foundation
import Observation
import Security

/// A saved website login. The site and username are stored as plain text (so the sidebar can
/// tell whether a page has saved logins without unlocking anything); the password is sealed
/// with AES-GCM under the vault key.
public struct SavedLogin: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// `scheme://host[:port]`.
    public var origin: String
    public var username: String
    public var sealedPassword: Data
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastUsedAt: Date?
    public var timesUsed: Int

    public var host: String { URL(string: origin)?.host() ?? origin }
}

/// Holds the vault's encryption key.
@MainActor
public protocol VaultKeyStore: AnyObject {
    func loadOrCreateKey() throws -> SymmetricKey
}

/// The vault key lives in the login keychain as a generic password ("Bezier Safe Storage"),
/// the same arrangement Chromium browsers use.
@MainActor
public final class KeychainVaultKeyStore: VaultKeyStore {
    static let service = "Bezier Safe Storage"
    static let account = "Bezier"

    public init() {}

    public func loadOrCreateKey() throws -> SymmetricKey {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: Self.account, kSecReturnData as String: true]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw PasswordVault.VaultError.keychain(status) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                  kSecAttrAccount as String: Self.account, kSecAttrLabel as String: Self.service,
                                  kSecValueData as String: data]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw PasswordVault.VaultError.keychain(added) }
        return key
    }
}

/// Saved logins, persisted as `Passwords.json` (owner-only) next to the sidebar file. The key
/// is fetched the first time a password is sealed or opened, not at launch.
@MainActor
@Observable
public final class PasswordVault {
    public enum VaultError: Error { case keychain(OSStatus), corrupt }
    public enum SaveResult: Equatable { case added, updated, unchanged }

    public private(set) var logins: [SavedLogin] = []
    /// Sites where the user chose "Never" for saving.
    public private(set) var neverSave: Set<String> = []

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let keyStore: any VaultKeyStore
    @ObservationIgnored private var key: SymmetricKey?

    private struct Snapshot: Codable {
        var logins: [SavedLogin]
        var neverSave: [String]
    }

    /// `directory: nil` keeps everything in memory (tests).
    public init(directory: URL? = BrowserStore.defaultDirectory, keyStore: any VaultKeyStore) {
        self.keyStore = keyStore
        fileURL = directory?.appending(path: "Passwords.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder.store.decode(Snapshot.self, from: data) {
            logins = snapshot.logins
            neverSave = Set(snapshot.neverSave)
        }
    }

    /// `scheme://host[:port]` for http(s) pages; nil for anything else.
    public nonisolated static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// Same site, treating `www.` as optional.
    nonisolated static func sameSite(_ a: String, _ b: String) -> Bool {
        func strip(_ s: String) -> String { s.replacingOccurrences(of: "://www.", with: "://") }
        return strip(a) == strip(b)
    }

    public func logins(for origin: String) -> [SavedLogin] {
        logins.filter { Self.sameSite($0.origin, origin) }
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    public func password(for login: SavedLogin) throws -> String {
        let box = try AES.GCM.SealedBox(combined: login.sealedPassword)
        let data = try AES.GCM.open(box, using: vaultKey())
        guard let password = String(data: data, encoding: .utf8) else { throw VaultError.corrupt }
        return password
    }

    /// Saves a login typed into a page: new, a changed password for a known username, or no-op.
    @discardableResult
    public func save(username: String, password: String, origin: String, at date: Date = .now) throws -> SaveResult {
        if let i = logins.firstIndex(where: { Self.sameSite($0.origin, origin) && $0.username == username }) {
            if (try? self.password(for: logins[i])) == password { return .unchanged }
            logins[i].sealedPassword = try seal(password)
            logins[i].modifiedAt = date
            persist()
            return .updated
        }
        logins.append(SavedLogin(id: UUID(), origin: origin, username: username, sealedPassword: try seal(password),
                                 createdAt: date, modifiedAt: date, lastUsedAt: nil, timesUsed: 0))
        persist()
        return .added
    }

    /// What saving this login would do, without saving it.
    public func pendingResult(username: String, password: String, origin: String) -> SaveResult {
        guard let login = logins.first(where: { Self.sameSite($0.origin, origin) && $0.username == username }) else { return .added }
        return (try? self.password(for: login)) == password ? .unchanged : .updated
    }

    public struct ImportedLogin: Sendable {
        public var origin: String
        public var username: String
        public var password: String
        public var createdAt: Date
        public var lastUsedAt: Date?
        public init(origin: String, username: String, password: String, createdAt: Date, lastUsedAt: Date?) {
            self.origin = origin; self.username = username; self.password = password
            self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
        }
    }

    /// Adds logins from another browser, skipping site + username pairs already saved.
    /// Returns how many were added.
    @discardableResult
    public func add(_ imported: [ImportedLogin], neverSave sites: [String] = []) throws -> Int {
        var added = 0
        for login in imported where !logins.contains(where: { Self.sameSite($0.origin, login.origin) && $0.username == login.username }) {
            logins.append(SavedLogin(id: UUID(), origin: login.origin, username: login.username, sealedPassword: try seal(login.password),
                                     createdAt: login.createdAt, modifiedAt: login.createdAt, lastUsedAt: login.lastUsedAt, timesUsed: 0))
            added += 1
        }
        neverSave.formUnion(sites)
        persist()
        return added
    }

    public func markUsed(_ login: SavedLogin, at date: Date = .now) {
        guard let i = logins.firstIndex(where: { $0.id == login.id }) else { return }
        logins[i].lastUsedAt = date
        logins[i].timesUsed += 1
        persist()
    }

    public func remove(_ login: SavedLogin) {
        logins.removeAll { $0.id == login.id }
        persist()
    }

    public func setNeverSave(_ origin: String, _ never: Bool = true) {
        if never { neverSave.insert(origin) } else { neverSave.remove(origin) }
        persist()
    }

    public func isNeverSave(_ origin: String) -> Bool { neverSave.contains { Self.sameSite($0, origin) } }

    // MARK: Storage

    private func vaultKey() throws -> SymmetricKey {
        if let key { return key }
        let loaded = try keyStore.loadOrCreateKey()
        key = loaded
        return loaded
    }

    private func seal(_ password: String) throws -> Data {
        guard let combined = try AES.GCM.seal(Data(password.utf8), using: vaultKey()).combined else { throw VaultError.corrupt }
        return combined
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder.store.encode(Snapshot(logins: logins, neverSave: neverSave.sorted())) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))
    }
}
