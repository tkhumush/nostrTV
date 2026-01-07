import Foundation

/// Manages persistence of bunker sessions to UserDefaults
class BunkerSessionManager {

    // MARK: - Constants

    private let sessionKey = "nostr_bunker_session"
    private let userDefaults = UserDefaults.standard

    // MARK: - Public Methods

    /// Save a bunker session to persistent storage
    /// - Parameter session: The bunker session to save
    func saveSession(_ session: BunkerSession) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            userDefaults.set(data, forKey: sessionKey)
            userDefaults.synchronize()
            print("✅ Bunker session saved: \(session.bunkerPubkey.prefix(8))...")
        } catch {
            print("❌ Failed to save bunker session: \(error.localizedDescription)")
        }
    }

    /// Load the saved bunker session from persistent storage
    /// - Returns: The saved session, or nil if none exists
    func loadSession() -> BunkerSession? {
        guard let data = userDefaults.data(forKey: sessionKey) else {
            print("ℹ️ No saved bunker session found")
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(BunkerSession.self, from: data)
            print("✅ Bunker session loaded: \(session.bunkerPubkey.prefix(8))...")
            return session
        } catch {
            print("❌ Failed to load bunker session: \(error.localizedDescription)")
            return nil
        }
    }

    /// Update the last used timestamp for the current session
    func updateLastUsed() {
        guard var session = loadSession() else {
            return
        }

        session.lastUsed = Date()
        saveSession(session)
    }

    /// Clear the saved bunker session
    func clearSession() {
        userDefaults.removeObject(forKey: sessionKey)
        userDefaults.synchronize()
        print("✅ Bunker session cleared")
    }

    /// Check if a valid session exists
    /// - Returns: true if a session is saved and not expired
    func hasValidSession() -> Bool {
        guard let session = loadSession() else {
            return false
        }

        // Check if session is not too old (e.g., 30 days)
        let maxAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days
        let age = Date().timeIntervalSince(session.lastUsed)

        return age < maxAge
    }
}
