import Foundation
import secp256k1

/// Represents a Nostr key pair with private and public keys
/// Implementation based on Damus iOS app
struct NostrKeyPair {
    let privateKey: Data  // 32-byte private key
    let publicKey: Data   // 32-byte x-only public key

    /// Generate a new random ephemeral key pair
    /// Matches Damus: generate_new_keypair() in Keys.swift
    static func generate() throws -> NostrKeyPair {
        let key = try secp256k1.Signing.PrivateKey()
        let privkey = key.rawRepresentation
        let pubkey = Data(key.publicKey.xonly.bytes)

        return NostrKeyPair(privateKey: privkey, publicKey: pubkey)
    }

    /// Initialize from existing private key (hex format)
    init(privateKeyHex: String) throws {
        guard let privateKeyData = Data(hex: privateKeyHex) else {
            throw NostrKeyError.invalidHexString
        }

        guard privateKeyData.count == 32 else {
            throw NostrKeyError.invalidKeyLength
        }

        // Generate public key from private key
        let key = try secp256k1.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let pubkey = Data(key.publicKey.xonly.bytes)

        self.privateKey = privateKeyData
        self.publicKey = pubkey
    }

    /// Initialize from nsec (bech32-encoded private key)
    init(nsec: String) throws {
        let decoded = try Bech32.decode(nsec)

        guard decoded.hrp == "nsec" else {
            throw NostrKeyError.invalidNsec
        }

        guard decoded.data.count == 32 else {
            throw NostrKeyError.invalidKeyLength
        }

        try self.init(privateKeyHex: decoded.data.hexString)
    }

    private init(privateKey: Data, publicKey: Data) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    // MARK: - Key Formats

    /// Private key in hex format
    var privateKeyHex: String {
        return privateKey.hexString
    }

    /// Public key in hex format
    var publicKeyHex: String {
        return publicKey.hexString
    }

    /// Private key in nsec (bech32) format
    var nsec: String {
        return (try? Bech32.encode(hrp: "nsec", data: privateKey)) ?? ""
    }

    /// Public key in npub (bech32) format
    var npub: String {
        return (try? Bech32.encode(hrp: "npub", data: publicKey)) ?? ""
    }

    // MARK: - Signing

    /// Sign a message hash using Schnorr signature
    /// Matches Damus: sign_id() in NostrEvent.swift
    /// - Parameter messageHash: 32-byte hash of the message to sign
    /// - Returns: 64-byte Schnorr signature
    func sign(messageHash: Data) throws -> Data {
        guard messageHash.count == 32 else {
            throw NostrKeyError.invalidMessageHash
        }

        let key = try secp256k1.Signing.PrivateKey(rawRepresentation: privateKey)

        // Generate 64 bytes of auxiliary randomness (Damus approach)
        var auxRand = (0..<64).map { _ in UInt8.random(in: 0...255) }
        var digest = [UInt8](messageHash)

        // Sign with Schnorr
        let signature = try key.schnorr.signature(message: &digest, auxiliaryRand: &auxRand)

        return signature.rawRepresentation
    }

    /// Verify a Schnorr signature
    /// - Parameters:
    ///   - signature: 64-byte Schnorr signature
    ///   - messageHash: 32-byte hash of the message
    /// - Returns: true if signature is valid
    /// Note: Verification to be implemented if needed
    func verify(signature: Data, messageHash: Data) -> Bool {
        // TODO: Implement signature verification using jb55 secp256k1 library
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

// MARK: - Data Extensions

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
    /// Matches Damus hex_encode implementation
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
