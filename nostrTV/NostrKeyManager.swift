import Foundation
import Combine

/// Manages Nostr key pairs for the application
/// Handles ephemeral key generation and storage
@MainActor
class NostrKeyManager: ObservableObject {
    static let shared = NostrKeyManager()

    @Published private(set) var currentKeyPair: NostrKeyPair?
    @Published private(set) var isKeyGenerated: Bool = false

    private let userDefaults = UserDefaults.standard
    private let privateKeyKey = "nostr_ephemeral_private_key"

    private init() {
        loadStoredKey()
    }

    // MARK: - Key Generation

    /// Generate a new ephemeral key pair
    /// This will replace any existing key pair
    func generateEphemeralKeyPair() throws {
        let keyPair = try NostrKeyPair.generate()
        self.currentKeyPair = keyPair
        self.isKeyGenerated = true

        print("Generated new ephemeral key pair:")
        print("npub: \(keyPair.npub)")
        print("nsec: \(keyPair.nsec)")
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
        print("Key pair saved to UserDefaults")
    }

    /// Load stored key pair from UserDefaults
    private func loadStoredKey() {
        guard let privateKeyHex = userDefaults.string(forKey: privateKeyKey) else {
            print("No stored key pair found")
            return
        }

        do {
            let keyPair = try NostrKeyPair(privateKeyHex: privateKeyHex)
            self.currentKeyPair = keyPair
            self.isKeyGenerated = true
            print("Loaded existing key pair from storage")
            print("npub: \(keyPair.npub)")
        } catch {
            print("Failed to load stored key pair: \(error)")
            clearStoredKey()
        }
    }

    /// Clear stored key pair
    func clearStoredKey() {
        userDefaults.removeObject(forKey: privateKeyKey)
        self.currentKeyPair = nil
        self.isKeyGenerated = false
        print("Cleared stored key pair")
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

        print("Imported key pair from nsec")
        print("npub: \(keyPair.npub)")
    }

    /// Import key pair from hex private key
    func importKeyPair(privateKeyHex: String, persist: Bool = true) throws {
        let keyPair = try NostrKeyPair(privateKeyHex: privateKeyHex)
        self.currentKeyPair = keyPair
        self.isKeyGenerated = true

        if persist {
            saveKeyPair(keyPair)
        }

        print("Imported key pair from hex")
        print("npub: \(keyPair.npub)")
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
