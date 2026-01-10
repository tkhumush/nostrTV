import Foundation
import Combine

/// Manages ephemeral Nostr key pairs for bunker client communication only
/// No persistence - keys are generated on-demand for bunker handshake
class NostrKeyManager: ObservableObject {
    static let shared = NostrKeyManager()

    @Published private(set) var currentKeyPair: NostrKeyPair?
    @Published private(set) var isKeyGenerated: Bool = false

    private init() {}

    // MARK: - Key Generation

    /// Generate a new ephemeral key pair for bunker client communication
    /// This is only used for the nostrconnect:// URI in bunker handshake
    func generateEphemeralKeyPair() throws {
        let keyPair = try NostrKeyPair.generate()
        self.currentKeyPair = keyPair
        self.isKeyGenerated = true
    }

    /// Clear current key pair
    func clearKeyPair() {
        self.currentKeyPair = nil
        self.isKeyGenerated = false
    }

    // MARK: - Key Info

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
