//
//  NostrEventValidator.swift
//  nostrTV
//
//  Created by Claude Code on 1/21/26.
//  Implements NIP-01 event validation and signature verification
//

import Foundation
import NostrSDK
@preconcurrency import secp256k1

// MARK: - Admin Configuration

/// Configuration for trusted admin pubkeys
/// Supports multi-admin setup for redundancy and security
struct AdminConfig {
    /// Primary admin pubkey for curated Discover feed
    /// Multiple admins can be added for redundancy
    static let adminPubkeys: Set<String> = [
        "f67a7093fdd829fae5796250cf0932482b1d7f40900110d0d932b5a7fb37755d"  // Primary admin
        // Add backup admins here as needed
    ]

    /// Minimum number of admins required for sensitive operations
    /// Currently set to 1 for single-admin mode
    static let quorumRequired = 1

    /// Check if a pubkey is a trusted admin
    /// - Parameter pubkey: The pubkey to check (hex format)
    /// - Returns: True if the pubkey is in the admin list
    static func isAdmin(_ pubkey: String) -> Bool {
        return adminPubkeys.contains(pubkey.lowercased())
    }

    /// Get the primary admin pubkey (first in the set)
    static var primaryAdmin: String {
        return adminPubkeys.first ?? ""
    }
}

// MARK: - Validation Errors

/// Errors that can occur during event validation
enum EventValidationError: Error, LocalizedError {
    case missingRequiredField(String)
    case missingRequiredTag(String)
    case invalidTagFormat(String)
    case invalidContent(String)
    case invalidEventId
    case signatureVerificationFailed
    case invalidTimestamp
    case eventTooOld(maxAge: TimeInterval)
    case eventFromFuture

    var errorDescription: String? {
        switch self {
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .missingRequiredTag(let tag):
            return "Missing required tag: \(tag)"
        case .invalidTagFormat(let message):
            return "Invalid tag format: \(message)"
        case .invalidContent(let message):
            return "Invalid content: \(message)"
        case .invalidEventId:
            return "Event ID does not match computed hash"
        case .signatureVerificationFailed:
            return "Schnorr signature verification failed"
        case .invalidTimestamp:
            return "Invalid timestamp"
        case .eventTooOld(let maxAge):
            return "Event is older than \(Int(maxAge)) seconds"
        case .eventFromFuture:
            return "Event timestamp is in the future"
        }
    }
}

// MARK: - Event Validator

/// Validates Nostr events according to NIP-01 and kind-specific requirements
struct NostrEventValidator {

    /// Maximum allowed age for events (24 hours)
    static let maxEventAge: TimeInterval = 24 * 60 * 60

    /// Maximum allowed future timestamp tolerance (5 minutes)
    static let maxFutureTolerance: TimeInterval = 5 * 60

    // MARK: - Full Validation

    /// Perform full validation on an event including signature verification
    /// - Parameter event: The NostrEvent to validate
    /// - Throws: EventValidationError if validation fails
    static func validate(_ event: NostrEvent) throws {
        // 1. Validate required fields exist
        try validateRequiredFields(event)

        // 2. Verify event ID matches hash
        try validateEventId(event)

        // 3. Verify Schnorr signature
        try validateSignature(event)

        // 4. Validate timestamp
        try validateTimestamp(event)

        // 5. Kind-specific validation
        try validateByKind(event)
    }

    /// Perform validation without signature verification (for trusted relay data)
    /// - Parameter event: The NostrEvent to validate
    /// - Throws: EventValidationError if validation fails
    static func validateWithoutSignature(_ event: NostrEvent) throws {
        try validateRequiredFields(event)
        try validateTimestamp(event)
        try validateByKind(event)
    }

    // MARK: - Field Validation

    /// Validate that all required fields are present
    private static func validateRequiredFields(_ event: NostrEvent) throws {
        guard event.id != nil, !event.id!.isEmpty else {
            throw EventValidationError.missingRequiredField("id")
        }
        guard event.pubkey != nil, !event.pubkey!.isEmpty else {
            throw EventValidationError.missingRequiredField("pubkey")
        }
        guard event.created_at != nil else {
            throw EventValidationError.missingRequiredField("created_at")
        }
        guard event.sig != nil, !event.sig!.isEmpty else {
            throw EventValidationError.missingRequiredField("sig")
        }
    }

    // MARK: - Event ID Validation

    /// Verify that the event ID matches the SHA256 hash of the serialized event
    private static func validateEventId(_ event: NostrEvent) throws {
        guard let eventId = event.id,
              let pubkey = event.pubkey,
              let createdAt = event.created_at else {
            throw EventValidationError.missingRequiredField("id, pubkey, or created_at")
        }

        let content = event.content ?? ""

        // Reconstruct the event array for hashing: [0, pubkey, created_at, kind, tags, content]
        let eventArray: [Any] = [0, pubkey, createdAt, event.kind, event.tags, content]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: eventArray,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw EventValidationError.invalidEventId
        }

        let computedHash = jsonData.sha256()
        let computedId = computedHash.hexString

        guard eventId.lowercased() == computedId.lowercased() else {
            print("⚠️ Event ID mismatch: expected \(computedId), got \(eventId)")
            throw EventValidationError.invalidEventId
        }
    }

    // MARK: - Signature Validation

    /// Verify the Schnorr signature of an event
    private static func validateSignature(_ event: NostrEvent) throws {
        guard let eventId = event.id,
              let pubkey = event.pubkey,
              let signature = event.sig else {
            throw EventValidationError.missingRequiredField("id, pubkey, or sig")
        }

        // Convert hex strings to Data
        guard let messageHash = Data(hex: eventId),
              let signatureData = Data(hex: signature),
              let pubkeyData = Data(hex: pubkey) else {
            throw EventValidationError.signatureVerificationFailed
        }

        // Verify signature using secp256k1 Schnorr
        let isValid = verifySchnorrSignature(
            message: messageHash,
            signature: signatureData,
            pubkey: pubkeyData
        )

        guard isValid else {
            print("⚠️ Signature verification failed for event \(eventId.prefix(16))...")
            throw EventValidationError.signatureVerificationFailed
        }
    }

    /// Verify a Schnorr signature using secp256k1
    /// - Parameters:
    ///   - message: 32-byte message hash
    ///   - signature: 64-byte Schnorr signature
    ///   - pubkey: 32-byte x-only public key
    /// - Returns: True if signature is valid
    private static func verifySchnorrSignature(message: Data, signature: Data, pubkey: Data) -> Bool {
        guard message.count == 32, signature.count == 64, pubkey.count == 32 else {
            print("⚠️ Invalid data lengths: message=\(message.count), sig=\(signature.count), pubkey=\(pubkey.count)")
            return false
        }

        do {
            // Create x-only public key from bytes
            let xOnlyKey = secp256k1.Schnorr.XonlyKey(
                dataRepresentation: [UInt8](pubkey),
                keyParity: 0
            )

            // Create signature object
            let schnorrSignature = try secp256k1.Schnorr.SchnorrSignature(
                dataRepresentation: [UInt8](signature)
            )

            // Verify signature - convert to mutable arrays as required by the API
            var messageBytes = [UInt8](message)
            return xOnlyKey.isValid(schnorrSignature, for: &messageBytes)
        } catch {
            print("⚠️ Schnorr verification error: \(error)")
            return false
        }
    }

    // MARK: - Timestamp Validation

    /// Validate event timestamp is reasonable
    private static func validateTimestamp(_ event: NostrEvent) throws {
        guard let createdAt = event.created_at else {
            throw EventValidationError.invalidTimestamp
        }

        let eventTime = Date(timeIntervalSince1970: TimeInterval(createdAt))
        let now = Date()

        // Check if event is from the future (with tolerance)
        if eventTime.timeIntervalSince(now) > maxFutureTolerance {
            throw EventValidationError.eventFromFuture
        }

        // Note: We don't enforce maxEventAge for historical data queries
        // Only enable this for real-time subscriptions if needed
    }

    // MARK: - Kind-Specific Validation

    /// Validate event based on its kind
    private static func validateByKind(_ event: NostrEvent) throws {
        switch event.kind {
        case 0:
            try validateMetadataEvent(event)
        case 30311:
            try validateLiveEventEvent(event)
        case 1311:
            try validateLiveChatEvent(event)
        case 9735:
            try validateZapReceiptEvent(event)
        default:
            // No specific validation for other kinds
            break
        }
    }

    /// Validate kind 0 (Metadata) event
    private static func validateMetadataEvent(_ event: NostrEvent) throws {
        guard let content = event.content, !content.isEmpty else {
            // Empty content is technically valid but not useful
            return
        }

        // Verify content is valid JSON
        guard let data = content.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventValidationError.invalidContent("Content must be valid JSON object")
        }
    }

    /// Validate kind 30311 (Live Event) event
    private static func validateLiveEventEvent(_ event: NostrEvent) throws {
        // Required: d-tag for addressable event identifier
        guard event.tags.contains(where: { $0.first == "d" && $0.count > 1 }) else {
            throw EventValidationError.missingRequiredTag("d")
        }

        // Optional but validate if present: status tag
        if let statusTag = event.tags.first(where: { $0.first == "status" }),
           statusTag.count > 1 {
            let status = statusTag[1]
            let validStatuses = ["live", "ended", "planned"]
            if !validStatuses.contains(status.lowercased()) {
                throw EventValidationError.invalidTagFormat("status must be one of: \(validStatuses.joined(separator: ", "))")
            }
        }
    }

    /// Validate kind 1311 (Live Chat) event
    private static func validateLiveChatEvent(_ event: NostrEvent) throws {
        // Required: a-tag referencing the stream
        guard let aTag = event.tags.first(where: { $0.first == "a" && $0.count > 1 }) else {
            throw EventValidationError.missingRequiredTag("a")
        }

        // Validate a-tag format: "30311:<pubkey>:<d-tag>"
        let aValue = aTag[1]
        let parts = aValue.split(separator: ":")
        guard parts.count >= 3,
              parts[0] == "30311",
              parts[1].count == 64 else {  // pubkey should be 64 hex chars
            throw EventValidationError.invalidTagFormat("a-tag must be in format '30311:<pubkey>:<d-tag>'")
        }
    }

    /// Validate kind 9735 (Zap Receipt) event
    private static func validateZapReceiptEvent(_ event: NostrEvent) throws {
        // Required: bolt11 tag with Lightning invoice
        guard event.tags.contains(where: { $0.first == "bolt11" && $0.count > 1 }) else {
            throw EventValidationError.missingRequiredTag("bolt11")
        }

        // Required: description tag with zap request
        guard let descTag = event.tags.first(where: { $0.first == "description" && $0.count > 1 }) else {
            throw EventValidationError.missingRequiredTag("description")
        }

        // Validate description is valid JSON (zap request)
        let description = descTag[1]
        guard let data = description.data(using: .utf8),
              let zapRequest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              zapRequest["pubkey"] != nil else {
            throw EventValidationError.invalidContent("description must be valid zap request JSON with pubkey")
        }
    }
}

// MARK: - NostrSDK Event Extension

extension NostrEventValidator {

    /// Validate a NostrSDK event
    /// - Parameter event: The NostrSDK.NostrEvent to validate
    /// - Throws: EventValidationError if validation fails
    static func validate(_ event: NostrSDK.NostrEvent) throws {
        // Convert to our format for validation
        let legacyEvent = NostrEvent(
            kind: event.kind.rawValue,
            tags: event.tags.map { [$0.name, $0.value] + $0.otherParameters },
            id: event.id,
            pubkey: event.pubkey,
            created_at: Int(event.createdAt),
            content: event.content,
            sig: event.signature
        )

        try validate(legacyEvent)
    }

    /// Validate without signature for NostrSDK events
    static func validateWithoutSignature(_ event: NostrSDK.NostrEvent) throws {
        let legacyEvent = NostrEvent(
            kind: event.kind.rawValue,
            tags: event.tags.map { [$0.name, $0.value] + $0.otherParameters },
            id: event.id,
            pubkey: event.pubkey,
            created_at: Int(event.createdAt),
            content: event.content,
            sig: event.signature
        )

        try validateWithoutSignature(legacyEvent)
    }
}

// MARK: - Batch Validation

extension NostrEventValidator {

    /// Validate multiple events, returning only valid ones
    /// - Parameters:
    ///   - events: Array of events to validate
    ///   - verifySignatures: Whether to verify signatures (slower but more secure)
    /// - Returns: Array of valid events
    static func filterValid(_ events: [NostrEvent], verifySignatures: Bool = false) -> [NostrEvent] {
        return events.filter { event in
            do {
                if verifySignatures {
                    try validate(event)
                } else {
                    try validateWithoutSignature(event)
                }
                return true
            } catch {
                print("⚠️ Event validation failed: \(error.localizedDescription)")
                return false
            }
        }
    }
}

// MARK: - aTag Utilities

extension NostrEventValidator {

    /// Normalize an a-tag for consistent lookups
    /// - Parameter aTag: The a-tag to normalize
    /// - Returns: Normalized a-tag with lowercase pubkey
    static func normalizeATag(_ aTag: String) -> String {
        let parts = aTag.split(separator: ":", maxSplits: 2)
        guard parts.count >= 3 else { return aTag.lowercased() }
        let kind = parts[0]
        let pubkey = parts[1].lowercased()
        let dTag = parts[2]
        return "\(kind):\(pubkey):\(dTag)"
    }

    /// Construct an a-tag from stream components
    /// - Parameters:
    ///   - pubkey: The event author pubkey (not p-tag host pubkey)
    ///   - dTag: The d-tag identifier
    /// - Returns: Properly formatted a-tag
    static func constructATag(pubkey: String, dTag: String) -> String {
        return "30311:\(pubkey.lowercased()):\(dTag)"
    }

    /// Validate and parse an a-tag
    /// - Parameter aTag: The a-tag to parse
    /// - Returns: Tuple of (kind, pubkey, dTag) or nil if invalid
    static func parseATag(_ aTag: String) -> (kind: Int, pubkey: String, dTag: String)? {
        let parts = aTag.split(separator: ":", maxSplits: 2)
        guard parts.count >= 3,
              let kind = Int(parts[0]),
              parts[1].count == 64 else {
            return nil
        }
        return (kind, String(parts[1]).lowercased(), String(parts[2]))
    }
}
