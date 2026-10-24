import CommonCrypto
import Foundation
import Security
import SQLite3

/// Arc's (and any Chromium browser's) saved passwords: the `Login Data` database in each
/// profile. Passwords are AES-128-CBC encrypted ("v10" prefix) with a key derived from the
/// browser's "… Safe Storage" secret in the login keychain. Reading that secret shows the
/// standard macOS keychain prompt.
public enum ArcPasswords {
    public struct EncryptedLogin: Sendable {
        public var origin: String
        public var username: String
        public var encryptedPassword: Data
        public var createdAt: Date
        public var lastUsedAt: Date?
        /// The user chose "Never" for this site in Arc.
        public var neverSave: Bool
    }

    /// Logins from every profile under `userData`, with passwords still encrypted. The
    /// databases are copied first because Arc keeps them locked while running.
    public static func read(userData: URL = ArcImporter.arcDirectory.appending(path: "User Data", directoryHint: .isDirectory)) -> [EncryptedLogin] {
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: userData.path(percentEncoded: false))) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted()
        return profiles.flatMap { readDatabase(userData.appending(path: $0).appending(path: "Login Data")) }
    }

    /// How many logins Arc has saved (for the import preview); nothing is decrypted.
    public static func count(userData: URL = ArcImporter.arcDirectory.appending(path: "User Data", directoryHint: .isDirectory)) -> Int {
        read(userData: userData).filter { !$0.neverSave }.count
    }

    static func readDatabase(_ source: URL) -> [EncryptedLogin] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { return [] }
        let temp = fm.temporaryDirectory.appending(path: "bezier-arc-logins-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path(percentEncoded: false))
            for suffix in ["", "-wal", "-journal"] where fm.fileExists(atPath: source.path(percentEncoded: false) + suffix) {
                try fm.copyItem(atPath: source.path(percentEncoded: false) + suffix,
                                toPath: temp.appending(path: "Login Data" + suffix).path(percentEncoded: false))
            }
        } catch { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appending(path: "Login Data").path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = "SELECT signon_realm, origin_url, username_value, password_value, date_created, date_last_used, blacklisted_by_user FROM logins"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        // Chromium time: microseconds since 1601-01-01 UTC; 0 means never.
        func date(_ column: Int32) -> Date? {
            let value = sqlite3_column_int64(statement, column)
            return value > 0 ? Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600) : nil
        }

        var logins: [EncryptedLogin] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let realm = text(0), originURL = text(1)
            guard let url = URL(string: realm.isEmpty ? originURL : realm), let origin = PasswordVault.origin(of: url) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 3))
            let blob = length > 0 ? sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: length) } ?? Data() : Data()
            logins.append(EncryptedLogin(origin: origin, username: text(2), encryptedPassword: blob,
                                         createdAt: date(4) ?? .now, lastUsedAt: date(5),
                                         neverSave: sqlite3_column_int(statement, 6) != 0))
        }
        return logins
    }

    public enum DecryptError: Error { case keychain(OSStatus) }

    /// A Chromium browser's "… Safe Storage" secret (Arc's by default). Blocks while macOS asks
    /// the user to allow access.
    public static func safeStorageSecret(service: String = "Arc Safe Storage", account: String = "Arc") throws -> Data {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw DecryptError.keychain(status) }
        return data
    }

    /// Chromium's macOS key: PBKDF2-HMAC-SHA1 over the secret, salt "saltysalt", 1003 rounds, 16 bytes.
    public static func derivedKey(secret: Data) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            secret.withUnsafeBytes { secretBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         secretBytes.baseAddress?.assumingMemoryBound(to: Int8.self), secret.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return status == kCCSuccess ? key : Data()
    }

    /// Decrypts a "v10" password value; nil if it isn't one or the key is wrong.
    public static func decrypt(_ value: Data, key: Data) -> String? {
        guard value.count > 3, value.prefix(3) == Data("v10".utf8), key.count == kCCKeySizeAES128 else { return nil }
        let cipher = value.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plain = Data(count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = plain.count
        let status = plain.withUnsafeMutableBytes { out in
            cipher.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, cipher.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: plain.prefix(written), encoding: .utf8)
    }

    /// Encrypts like Chromium does (tests build fixtures with it).
    static func encrypt(_ password: String, key: Data) -> Data {
        let input = Data(password.utf8)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = out.count
        _ = out.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, outBytes.baseAddress, capacity, &written)
                    }
                }
            }
        }
        return Data("v10".utf8) + out.prefix(written)
    }

    public struct Decrypted: Sendable {
        public var logins: [PasswordVault.ImportedLogin]
        public var neverSave: [String]
        /// Entries that couldn't be decrypted (another key, or an unknown format).
        public var failed: Int
    }

    /// Reads and decrypts everything. Call off the main thread: the keychain prompt blocks.
    /// Works for any Chromium browser given its user data folder and keychain item.
    public static func readDecrypted(userData: URL = ArcImporter.arcDirectory.appending(path: "User Data", directoryHint: .isDirectory),
                                     service: String = "Arc Safe Storage", account: String = "Arc") throws -> Decrypted {
        let encrypted = read(userData: userData)
        guard encrypted.contains(where: { !$0.neverSave }) else {
            return Decrypted(logins: [], neverSave: encrypted.map(\.origin), failed: 0)
        }
        let key = derivedKey(secret: try safeStorageSecret(service: service, account: account))
        var result = Decrypted(logins: [], neverSave: [], failed: 0)
        for login in encrypted {
            if login.neverSave { result.neverSave.append(login.origin); continue }
            guard let password = decrypt(login.encryptedPassword, key: key), !password.isEmpty else { result.failed += 1; continue }
            result.logins.append(PasswordVault.ImportedLogin(origin: login.origin, username: login.username, password: password,
                                                             createdAt: login.createdAt, lastUsedAt: login.lastUsedAt))
        }
        return result
    }
}
