import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import BezierCore

@MainActor
private final class MemoryKeyStore: VaultKeyStore {
    let key = SymmetricKey(size: .bits256)
    func loadOrCreateKey() throws -> SymmetricKey { key }
}

@MainActor
struct PasswordVaultTests {
    @Test func originsAreSchemeHostAndPort() {
        #expect(PasswordVault.origin(of: URL(string: "https://Accounts.Example.com/login?x=1")!) == "https://accounts.example.com")
        #expect(PasswordVault.origin(of: URL(string: "http://localhost:3000/a")!) == "http://localhost:3000")
        #expect(PasswordVault.origin(of: URL(string: "file:///tmp/a.html")!) == nil)
    }

    @Test func savesSealsAndUpdates() throws {
        let vault = PasswordVault(directory: nil, keyStore: MemoryKeyStore())
        #expect(try vault.save(username: "ana", password: "one", origin: "https://example.com") == .added)
        #expect(try vault.save(username: "ana", password: "one", origin: "https://www.example.com") == .unchanged)
        #expect(try vault.save(username: "ana", password: "two", origin: "https://example.com") == .updated)
        let login = try #require(vault.logins(for: "https://www.example.com").first)
        #expect(try vault.password(for: login) == "two")
        #expect(!login.sealedPassword.contains(Data("two".utf8)))
        #expect(vault.logins(for: "https://example.org").isEmpty)
    }

    @Test func persistsAcrossLaunchesWithTheSameKey() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = MemoryKeyStore()
        try PasswordVault(directory: dir, keyStore: keys).save(username: "ana", password: "secret", origin: "https://example.com")
        let reopened = PasswordVault(directory: dir, keyStore: keys)
        #expect(try reopened.password(for: try #require(reopened.logins.first)) == "secret")
        let raw = try String(contentsOf: dir.appending(path: "Passwords.json"), encoding: .utf8)
        #expect(!raw.contains("secret"))
    }

    @Test func importSkipsKnownLogins() throws {
        let vault = PasswordVault(directory: nil, keyStore: MemoryKeyStore())
        try vault.save(username: "ana", password: "mine", origin: "https://example.com")
        let added = try vault.add([
            .init(origin: "https://example.com", username: "ana", password: "theirs", createdAt: .now, lastUsedAt: nil),
            .init(origin: "https://example.org", username: "ben", password: "pw", createdAt: .now, lastUsedAt: nil),
        ], neverSave: ["https://bank.example"])
        #expect(added == 1)
        #expect(try vault.password(for: vault.logins(for: "https://example.com")[0]) == "mine")
        #expect(vault.isNeverSave("https://bank.example"))
    }
}

@MainActor
struct ArcPasswordTests {
    @Test func decryptsChromiumV10Values() {
        let key = ArcPasswords.derivedKey(secret: Data("peanuts".utf8))
        #expect(key.count == 16)
        let blob = ArcPasswords.encrypt("hunter2 ✓", key: key)
        #expect(blob.prefix(3) == Data("v10".utf8))
        #expect(ArcPasswords.decrypt(blob, key: key) == "hunter2 ✓")
        #expect(ArcPasswords.decrypt(blob, key: ArcPasswords.derivedKey(secret: Data("other".utf8))) == nil)
    }

    /// Fixtures made outside Swift: the key with Python's hashlib.pbkdf2_hmac, the ciphertext with
    /// `openssl enc -aes-128-cbc -iv 2020…20`.
    @Test func matchesIndependentFixtures() {
        let key = ArcPasswords.derivedKey(secret: Data("peanuts".utf8))
        #expect(key.map { String(format: "%02x", $0) }.joined() == "d9a09d499b4e1b7461f28e67972c6dbd")
        let cipher = Data([0x72, 0x18, 0xb8, 0xec, 0x87, 0x74, 0xbc, 0xaa, 0xd0, 0xe8, 0x30, 0x5f, 0x7a, 0x6c, 0xf9, 0x65])
        #expect(ArcPasswords.decrypt(Data("v10".utf8) + cipher, key: key) == "hunter2")
    }

    @Test func readsLoginDataFromEveryProfile() throws {
        let userData = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = ArcPasswords.derivedKey(secret: Data("secret".utf8))
        for (profile, rows) in [("Default", [("https://example.com/", "ana", "pw1", 0)]),
                                ("Profile 1", [("https://bank.example/", "", "", 1), ("android://x@com.app/", "c", "pw", 0)])] {
            let dir = userData.appending(path: profile)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var db: OpaquePointer?
            sqlite3_open(dir.appending(path: "Login Data").path(percentEncoded: false), &db)
            sqlite3_exec(db, """
                CREATE TABLE logins (origin_url VARCHAR NOT NULL, username_value VARCHAR, password_value BLOB,
                signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL,
                date_last_used INTEGER NOT NULL DEFAULT 0)
                """, nil, nil, nil)
            for (realm, user, password, never) in rows {
                var statement: OpaquePointer?
                sqlite3_prepare_v2(db, "INSERT INTO logins VALUES (?, ?, ?, ?, 13300000000000000, ?, 0)", -1, &statement, nil)
                let blob = password.isEmpty ? Data() : ArcPasswords.encrypt(password, key: key)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, realm, -1, transient)
                sqlite3_bind_text(statement, 2, user, -1, transient)
                _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(blob.count), transient) }
                sqlite3_bind_text(statement, 4, realm, -1, transient)
                sqlite3_bind_int(statement, 5, Int32(never))
                sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
            sqlite3_close(db)
        }
        let logins = ArcPasswords.read(userData: userData)
        #expect(logins.map(\.origin) == ["https://example.com", "https://bank.example"])     // android:// skipped
        #expect(logins[1].neverSave)
        #expect(ArcPasswords.decrypt(logins[0].encryptedPassword, key: key) == "pw1")
        #expect(ArcPasswords.count(userData: userData) == 1)
    }
}
