import Foundation
import NostrSDK
import secp256k1

/// Represents a Nostr key pair with private and public keys
/// Implementation based on NostrSDK
struct NostrKeyPair {
    let privateKey: PrivateKey  // NostrSDK PrivateKey
    let publicKey: PublicKey   // NostrSDK PublicKey

    /// Generate a new random ephemeral key pair
    static func generate() throws -> NostrKeyPair {
        guard let keypair = Keypair() else {
            throw NostrKeyError.keyGenerationFailed
        }

        return NostrKeyPair(privateKey: keypair.privateKey, publicKey: keypair.publicKey)
    }

    /// Initialize from existing private key (hex format)
    init(privateKeyHex: String) throws {
        guard let privateKey = PrivateKey(hex: privateKeyHex) else {
            throw NostrKeyError.invalidPrivateKey
        }

        guard let keypair = Keypair(privateKey: privateKey) else {
            throw NostrKeyError.publicKeyDerivationFailed
        }

        self.privateKey = keypair.privateKey
        self.publicKey = keypair.publicKey
    }

    /// Initialize from nsec (bech32-encoded private key)
    init(nsec: String) throws {
        guard let privateKey = PrivateKey(nsec: nsec) else {
            throw NostrKeyError.invalidNsec
        }

        guard let keypair = Keypair(privateKey: privateKey) else {
            throw NostrKeyError.publicKeyDerivationFailed
        }

        self.privateKey = keypair.privateKey
        self.publicKey = keypair.publicKey
    }

    private init(privateKey: PrivateKey, publicKey: PublicKey) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    // MARK: - Key Formats

    /// Private key in hex format
    var privateKeyHex: String {
        return privateKey.hex
    }

    /// Public key in hex format
    var publicKeyHex: String {
        return publicKey.hex
    }

    /// Private key in nsec (bech32) format
    var nsec: String {
        return privateKey.nsec
    }

    /// Public key in npub (bech32) format
    var npub: String {
        return publicKey.npub
    }

    // MARK: - Signing

    /// Sign a message hash using Schnorr signature
    /// Uses NostrSDK's secp256k1 Schnorr signing
    /// - Parameter messageHash: 32-byte hash of the message to sign
    /// - Returns: 64-byte Schnorr signature
    func sign(messageHash: Data) throws -> Data {
        guard messageHash.count == 32 else {
            throw NostrKeyError.invalidMessageHash
        }

        // Use secp256k1 Schnorr signing (matching NostrSDK pattern)
        guard let signingKey = try? secp256k1.Schnorr.PrivateKey(
            dataRepresentation: privateKey.dataRepresentation
        ) else {
            throw NostrKeyError.signingFailed
        }

        // Generate 64 bytes of auxiliary randomness per BIP-340
        var auxRand = (0..<64).map { _ in UInt8.random(in: 0...255) }
        var digest = [UInt8](messageHash)

        // Sign with Schnorr
        guard let signature = try? signingKey.signature(
            message: &digest,
            auxiliaryRand: &auxRand
        ) else {
            throw NostrKeyError.signingFailed
        }

        return signature.dataRepresentation
    }

    /// Verify a Schnorr signature
    /// - Parameters:
    ///   - signature: 64-byte Schnorr signature
    ///   - messageHash: 32-byte hash of the message
    /// - Returns: true if signature is valid
    func verify(signature: Data, messageHash: Data) -> Bool {
        // TODO: Implement signature verification using NostrSDK
        // For now, we primarily need signing capability
        return false
    }
}

// MARK: - Errors

enum NostrKeyError: Error {
    case keyGenerationFailed
    case invalidPrivateKey
    case invalidPublicKey
    case invalidHexString
    case invalidKeyLength
    case invalidNsec
    case invalidNpub
    case invalidMessageHash
    case publicKeyDerivationFailed
    case publicKeySerializationFailed
    case signingFailed
    case verificationFailed
}

// MARK: - Data Extensions (kept for compatibility)

extension Data {
    /// Convert hex string to Data
    init?(hex: String) {
        let length = hex.count / 2
        var data = Data(capacity: length)

        var index = hex.startIndex
        for _ in 0..<length {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Convert Data to hex string
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
