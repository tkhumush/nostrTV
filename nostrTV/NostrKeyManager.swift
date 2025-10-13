import Foundation
import Combine

/// Manages Nostr key pairs for the application
/// Handles ephemeral key generation and storage
class NostrKeyManager: ObservableObject {
    static let shared = NostrKeyManager()

    @Published private(set) var currentKeyPair: NostrKeyPair?
    @Published private(set) var isKeyGenerated: Bool = false
    @Published private(set) var hasPublishedProfile: Bool = false

    private let userDefaults = UserDefaults.standard
    private let privateKeyKey = "nostr_ephemeral_private_key"
    private let profilePublishedKey = "nostr_ephemeral_profile_published"

    private init() {
        loadStoredKey()
        hasPublishedProfile = userDefaults.bool(forKey: profilePublishedKey)
    }

    // MARK: - Key Generation

    /// Generate a new ephemeral key pair
    /// This will replace any existing key pair
    func generateEphemeralKeyPair() throws {
        let keyPair = try NostrKeyPair.generate()
        self.currentKeyPair = keyPair
        self.isKeyGenerated = true
    }

    /// Generate and save key pair to UserDefaults
    /// - Parameter persist: If true, saves the key to UserDefaults
    func generateAndSaveKeyPair(persist: Bool = true) throws {
        try generateEphemeralKeyPair()

        if persist, let keyPair = currentKeyPair {
            saveKeyPair(keyPair)
        }
    }

    // MARK: - Key Storage

    /// Save key pair to UserDefaults
    private func saveKeyPair(_ keyPair: NostrKeyPair) {
        userDefaults.set(keyPair.privateKeyHex, forKey: privateKeyKey)
    }

    /// Load stored key pair from UserDefaults
    private func loadStoredKey() {
        guard let privateKeyHex = userDefaults.string(forKey: privateKeyKey) else {
            do {
                try generateAndSaveKeyPair(persist: true)
            } catch {
                // Failed to generate ephemeral key pair
            }
            return
        }

        do {
            let keyPair = try NostrKeyPair(privateKeyHex: privateKeyHex)
            self.currentKeyPair = keyPair
            self.isKeyGenerated = true
        } catch {
            clearStoredKey()
            // Try to generate a new one
            do {
                try generateAndSaveKeyPair(persist: true)
            } catch {
                // Failed to generate new key pair
            }
        }
    }

    /// Clear stored key pair
    func clearStoredKey() {
        userDefaults.removeObject(forKey: privateKeyKey)
        self.currentKeyPair = nil
        self.isKeyGenerated = false
    }

    // MARK: - Import Keys

    /// Import key pair from nsec (bech32 private key)
    func importKeyPair(nsec: String, persist: Bool = true) throws {
        let keyPair = try NostrKeyPair(nsec: nsec)
        self.currentKeyPair = keyPair
        self.isKeyGenerated = true

        if persist {
            saveKeyPair(keyPair)
        }
    }

    /// Import key pair from hex private key
    func importKeyPair(privateKeyHex: String, persist: Bool = true) throws {
        let keyPair = try NostrKeyPair(privateKeyHex: privateKeyHex)
        self.currentKeyPair = keyPair
        self.isKeyGenerated = true

        if persist {
            saveKeyPair(keyPair)
        }
    }

    // MARK: - Signing

    /// Sign a Nostr event with the current key pair
    /// - Parameter eventData: The event data to sign (should be serialized JSON)
    /// - Returns: Hex-encoded signature
    func signEvent(_ eventData: Data) throws -> String {
        guard let keyPair = currentKeyPair else {
            throw NostrKeyError.invalidPrivateKey
        }

        // Hash the event data with SHA256
        let messageHash = eventData.sha256()

        // Sign with Schnorr
        let signature = try keyPair.sign(messageHash: messageHash)

        return signature.hexString
    }

    /// Sign a Nostr event JSON string
    /// - Parameter eventJSON: JSON string representing the event to sign
    /// - Returns: Hex-encoded signature
    func signEvent(eventJSON: String) throws -> String {
        guard let eventData = eventJSON.data(using: .utf8) else {
            throw NostrKeyError.invalidMessageHash
        }

        return try signEvent(eventData)
    }

    // MARK: - Key Info

    /// Get current public key in npub format
    var npub: String? {
        return currentKeyPair?.npub
    }

    /// Get current public key in hex format
    var publicKeyHex: String? {
        return currentKeyPair?.publicKeyHex
    }

    /// Check if a key pair is available
    var hasKeyPair: Bool {
        return currentKeyPair != nil
    }

    // MARK: - Profile Publishing

    /// Publish a profile metadata event (kind 0) for this ephemeral key
    /// - Parameter nostrClient: The NostrClient to use for publishing
    func publishEphemeralProfile(using nostrClient: NostrClient) throws {
        guard let keyPair = currentKeyPair else {
            throw NostrKeyError.invalidPrivateKey
        }

        // Generate a random bot-like name
        let adjectives = ["Swift", "Quick", "Bright", "Silent", "Bold", "Calm", "Noble", "Wise", "Free"]
        let nouns = ["Watcher", "Viewer", "Observer", "Guest", "Visitor", "Traveler", "Wanderer"]
        let randomAdjective = adjectives.randomElement()!
        let randomNoun = nouns.randomElement()!
        let randomNumber = Int.random(in: 100...999)
        let displayName = "\(randomAdjective) \(randomNoun) \(randomNumber)"

        // Create profile metadata JSON
        let profileMetadata: [String: Any] = [
            "name": "nostrtv_\(randomNumber)",
            "display_name": displayName,
            "about": "Ephemeral nostrTV viewer",
            "picture": "https://api.dicebear.com/7.x/bottts/svg?seed=\(keyPair.publicKeyHex)"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: profileMetadata),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NostrKeyError.signingFailed
        }

        // Create and sign the profile event (kind 0)
        let profileEvent = try nostrClient.createSignedEvent(
            kind: 0,
            content: jsonString,
            tags: [],
            using: keyPair
        )

        // Publish to relays
        try nostrClient.publishEvent(profileEvent)

        // Mark as published
        userDefaults.set(true, forKey: profilePublishedKey)
        hasPublishedProfile = true

        print("\n" + String(repeating: "=", count: 80))
        print("📝 EPHEMERAL PROFILE PUBLISHED")
        print(String(repeating: "=", count: 80))
        print("Display Name: \(displayName)")
        print("Username:     nostrtv_\(randomNumber)")
        print("About:        Ephemeral nostrTV viewer")
        print("npub:         \(keyPair.npub)")
        print("Pubkey (hex): \(keyPair.publicKeyHex)")
        print("Profile JSON:")
        print(jsonString)
        print(String(repeating: "=", count: 80) + "\n")
    }
}

// MARK: - SHA256 Extension

import CommonCrypto

extension Data {
    /// Calculate SHA256 hash of data
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
    }
}
