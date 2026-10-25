import Foundation
import Security
import Testing
@testable import CoveIOS

@MainActor
@Suite(.serialized)
struct CredentialSecurityTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "security-tests-\(UUID().uuidString)")!
    }

    private func session() throws -> BunkerSession {
        BunkerSession(bunkerPubkey: "signer", relay: "wss://example.com",
                      userPubkey: "user", clientPrivateKeyHex: try NostrKeyPair.generate().privateKeyHex)
    }

    @Test func keychainRoundTripReplacementAndProtection() throws {
        let service = "security-tests-\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        let account = "test-credential"
        defer { _ = store.delete(account: account) }
        #expect(store.save(Data("first".utf8), account: account))
        #expect(store.save(Data("replacement".utf8), account: account))
        #expect(store.load(account: account) == Data("replacement".utf8))
        var result: AnyObject?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne]
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attrs = try #require(result as? [String: Any])
        #expect(attrs[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect((attrs[kSecAttrSynchronizable as String] as? Bool) != true)
        #expect(store.delete(account: account))
        #expect(store.delete(account: account))
        #expect(store.load(account: account) == nil)
    }

    @Test func bunkerMigratesOutOfPreferencesAndSignsOut() throws {
        let defaults = isolatedDefaults()
        let store = MemoryCredentials()
        let manager = BunkerSessionManager(userDefaults: defaults, credentials: store)
        let original = try session()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(original), forKey: "nostr_bunker_session")
        #expect(manager.loadSession()?.clientPrivateKeyHex == original.clientPrivateKeyHex)
        #expect(defaults.object(forKey: "nostr_bunker_session") == nil)
        #expect(store.values[KeychainHelper.bunkerAccount] != nil)
        #expect(manager.loadSession()?.userPubkey == "user")
        #expect(manager.clearSession())
        #expect(manager.loadSession() == nil)
    }

    @Test func failedMigrationPurgesPlaintextAndDoesNotRestore() throws {
        let defaults = isolatedDefaults()
        let store = MemoryCredentials(); store.failSave = true
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(session()), forKey: "nostr_bunker_session")
        let manager = BunkerSessionManager(userDefaults: defaults, credentials: store)
        #expect(manager.loadSession() == nil)
        #expect(defaults.object(forKey: "nostr_bunker_session") == nil)
        #expect(store.values.isEmpty)
    }

    @Test func localSigningLoadsKeyOnDemandAndProducesOnlyPublicEventData() async throws {
        let store = MemoryCredentials()
        let client = try NostrSDKClient(relayURLs: [])
        let auth = OfflineSecurityAuth(nostrSDKClient: client, restoreSession: false,
                                      credentials: store, userDefaults: isolatedDefaults())
        let key = try NostrKeyPair.generate()
        try await auth.authenticateWithNsec(key.nsec)
        #expect(auth.isAuthenticated)
        #expect(!String(reflecting: auth.authMethod).contains(key.nsec))
        #expect(!String(reflecting: auth.authMethod).contains(key.privateKeyHex))
        var event = LegacyNostrEvent(kind: 1, tags: [])
        event.content = "security regression fixture"
        let signed = try await auth.signEvent(event)
        try NostrEventValidator.validate(signed)
        let json = String(decoding: try JSONEncoder().encode(signed), as: UTF8.self)
        #expect(!json.contains(key.nsec))
        #expect(!json.contains(key.privateKeyHex))
        #expect(signed.pubkey == key.publicKeyHex)
        store.denyRead = true
        await #expect(throws: NostrAuthError.self) { try await auth.signEvent(event) }
        store.denyRead = false
        #expect(auth.logout())
        #expect(store.values.isEmpty)
        await #expect(throws: NostrAuthError.self) { try await auth.signEvent(event) }
    }

    @Test func storageAndDeletionFailuresAreSurfaced() async throws {
        let store = MemoryCredentials()
        let auth = OfflineSecurityAuth(nostrSDKClient: try NostrSDKClient(relayURLs: []),
            restoreSession: false, credentials: store, userDefaults: isolatedDefaults())
        let key = try NostrKeyPair.generate()
        store.failSave = true
        await #expect(throws: NostrAuthError.self) { try await auth.authenticateWithNsec(key.nsec) }
        #expect(!auth.isAuthenticated)
        store.failSave = false
        try await auth.authenticateWithNsec(key.nsec)
        store.failDelete = true
        #expect(!auth.logout())
        #expect(auth.errorMessage != nil)
        #expect(auth.isAuthenticated)
        store.failDelete = false
        #expect(auth.logout())
        #expect(!auth.isAuthenticated)
    }


    @Test func bunkerStorageFailureCannotAuthenticateAndSwitchingRemovesOldCredentials() async throws {
        let store = MemoryCredentials()
        let auth = OfflineSecurityAuth(nostrSDKClient: try NostrSDKClient(relayURLs: []),
            restoreSession: false, credentials: store, userDefaults: isolatedDefaults())
        let key = try NostrKeyPair.generate()
        let signer = NostrBunkerClient(keyManager: NostrKeyManager.shared)
        try signer.restoreFromSession(bunkerPubkey: key.publicKeyHex,
            relays: ["wss://example.com"], clientPrivateKeyHex: key.privateKeyHex)
        store.failSave = true
        await #expect(throws: NostrAuthError.self) {
            try await auth.authenticateWithBunker(bunkerClient: signer, userPubkey: key.publicKeyHex)
        }
        #expect(!auth.isAuthenticated)
        #expect(signer.clientPrivateKeyHex == nil)
        store.failSave = false
        try signer.restoreFromSession(bunkerPubkey: key.publicKeyHex,
            relays: ["wss://example.com"], clientPrivateKeyHex: key.privateKeyHex)
        try await auth.authenticateWithNsec(key.nsec)
        try await auth.authenticateWithBunker(bunkerClient: signer, userPubkey: key.publicKeyHex)
        #expect(store.values[KeychainHelper.nsecAccount] == nil)
        #expect(store.values[KeychainHelper.bunkerAccount] != nil)
        try await auth.authenticateWithNsec(key.nsec)
        #expect(store.values[KeychainHelper.bunkerAccount] == nil)
        #expect(signer.clientPrivateKeyHex == nil)
        #expect(auth.logout())
    }

    @Test func deletingRemoteConnectionRemovesItsKeyAndNextPairingUsesANewIdentity() async throws {
        let store = MemoryCredentials()
        let defaults = isolatedDefaults()
        let manager = NostrKeyManager.shared
        defer { manager.clearKeyPair() }
        try manager.generateEphemeralKeyPair()
        let first = try #require(manager.currentKeyPair)
        let signer = NostrBunkerClient(keyManager: manager)
        try signer.restoreFromSession(bunkerPubkey: first.publicKeyHex,
            relays: ["wss://example.com"], clientPrivateKeyHex: first.privateKeyHex)
        let auth = OfflineSecurityAuth(nostrSDKClient: try NostrSDKClient(relayURLs: []),
            restoreSession: false, credentials: store, userDefaults: defaults)
        try await auth.authenticateWithBunker(bunkerClient: signer, userPubkey: first.publicKeyHex)

        // Reopening an existing connection must retain its authorized client identity.
        let sessions = BunkerSessionManager(userDefaults: defaults, credentials: store)
        let saved = try #require(sessions.loadSession())
        let restored = try NostrKeyPair(privateKeyHex: saved.clientPrivateKeyHex)
        #expect(restored.publicKeyHex == first.publicKeyHex)

        // Deleting the connection removes both the persistent and live credentials.
        #expect(auth.logout())
        #expect(sessions.loadSession() == nil)
        #expect(signer.clientPrivateKeyHex == nil)
        #expect(!manager.hasKeyPair)
        #expect(auth.bunkerClient == nil)

        try manager.generateEphemeralKeyPair()
        let secondPublicKey = try #require(manager.publicKeyHex)
        #expect(secondPublicKey != first.publicKeyHex)
    }

    @Test func diagnosticDescriptionsDoNotExposeCredentials() throws {
        let key = try NostrKeyPair.generate()
        let saved = try session()
        for description in [String(describing: key), String(reflecting: key),
                            String(describing: saved), String(reflecting: saved)] {
            #expect(!description.contains(key.nsec))
            #expect(!description.contains(key.privateKeyHex))
            #expect(!description.contains(saved.clientPrivateKeyHex))
        }
        #expect(!BunkerError.remoteError(key.nsec).localizedDescription.contains(key.nsec))
    }

    @Test func accountMismatchCannotSignAndInvalidInputIsNotStored() async throws {
        let store = MemoryCredentials()
        let auth = OfflineSecurityAuth(nostrSDKClient: try NostrSDKClient(relayURLs: []),
            restoreSession: false, credentials: store, userDefaults: isolatedDefaults())
        await #expect(throws: NostrAuthError.self) { try await auth.authenticateWithNsec("invalid") }
        #expect(store.values.isEmpty)
        try await auth.authenticateWithNsec(NostrKeyPair.generate().nsec)
        store.values[KeychainHelper.nsecAccount] = Data(try NostrKeyPair.generate().nsec.utf8)
        await #expect(throws: NostrAuthError.self) {
            try await auth.signEvent(LegacyNostrEvent(kind: 1, tags: []))
        }
    }
}

private final class MemoryCredentials: CredentialStore {
    var values: [String: Data] = [:]
    var failSave = false
    var failDelete = false
    var denyRead = false
    func save(_ data: Data, account: String) -> Bool {
        guard !failSave else { return false }
        values[account] = data
        return true
    }
    func load(account: String) -> Data? { denyRead ? nil : values[account] }
    func delete(account: String) -> Bool {
        guard !failDelete else { return false }
        values.removeValue(forKey: account)
        return true
    }
}

private final class OfflineSecurityAuth: NostrAuthManager {
    override func fetchUserData(force: Bool = false) {}
}
