import Foundation

/// The client key authorizes remote signing and is a credential, not a preference.
final class BunkerSessionManager {
    private let sessionKey = "nostr_bunker_session"
    private let userDefaults: UserDefaults
    private let credentials: any CredentialStore

    init(userDefaults: UserDefaults = .standard, credentials: any CredentialStore = KeychainStore()) {
        self.userDefaults = userDefaults
        self.credentials = credentials
    }

    @discardableResult
    func saveSession(_ session: BunkerSession) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session),
              credentials.save(data, account: KeychainHelper.bunkerAccount) else { return false }
        userDefaults.removeObject(forKey: sessionKey)
        return true
    }

    func loadSession() -> BunkerSession? {
        // Remove the legacy plaintext even if migration fails. Reauthentication is
        // safer than retaining a signing credential in preferences/backups.
        let legacy = userDefaults.data(forKey: sessionKey)
        userDefaults.removeObject(forKey: sessionKey)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = credentials.load(account: KeychainHelper.bunkerAccount) {
            return try? decoder.decode(BunkerSession.self, from: data)
        }
        guard let legacy,
              let session = try? decoder.decode(BunkerSession.self, from: legacy),
              saveSession(session) else { return nil }
        return session
    }

    func updateLastUsed() {
        guard var session = loadSession() else { return }
        session.lastUsed = Date()
        saveSession(session)
    }

    @discardableResult
    func clearSession() -> Bool {
        userDefaults.removeObject(forKey: sessionKey)
        return credentials.delete(account: KeychainHelper.bunkerAccount)
    }

    func hasValidSession() -> Bool {
        guard let session = loadSession() else { return false }
        return Date().timeIntervalSince(session.lastUsed) < 30 * 24 * 60 * 60
    }
}
