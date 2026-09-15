//
//  LegacyNostrEvent.swift
//  nostrTV
//
//  Event model used for creating, signing and publishing events.
//
//  Extracted from the retired NostrClient.swift. Previously this type was named
//  `NostrEvent`, which collided with `NostrSDK.NostrEvent` and forced call sites
//  throughout NostrSDKClient to disambiguate with module-qualified names
//  (`NostrSDK.NostrEvent` vs `nostrTV.NostrEvent`). The rename removes that
//  ambiguity: SDK events read as `NostrEvent`, ours as `LegacyNostrEvent`.
//

import Foundation

/// App-side Nostr event used for signing and publishing.
///
/// The NostrSDK has its own event type, but signing goes through NIP-46 bunkers
/// and local keypairs, which exchange this JSON shape directly. `NostrSDKClient`
/// converts between the two at the boundary.
struct LegacyNostrEvent: Codable {
    let kind: Int
    let tags: [[String]]

    // Full event structure for creating and signing
    var id: String?
    var pubkey: String?
    var created_at: Int?
    var content: String?
    var sig: String?

    enum CodingKeys: String, CodingKey {
        case id, pubkey, created_at, content, kind, tags, sig
    }
}

/// Errors raised while building, signing or publishing a `LegacyNostrEvent`.
enum NostrEventError: Error {
    case serializationFailed
    case incompleteEvent
    case signingFailed
    case publishFailed
}
