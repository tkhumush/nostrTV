//
//  NostrMention.swift
//  nostrTV
//

import Foundation
import NostrSDK

/// A piece of message content: either literal text, or someone who was tagged.
enum MessageSegment: Equatable {
    case text(String)

    /// A NIP-27 mention. `identifier` is the original bech32 token, kept so the UI has
    /// something to show for someone whose profile has not arrived (or does not exist).
    case mention(pubkey: String, identifier: String)
}

/// Finds `nostr:` mentions in message content and resolves them to pubkeys.
///
/// Chat carries tags as NIP-19 identifiers — `nostr:npub1…` for a bare public key and
/// `nostr:nprofile1…` for a public key bundled with relay hints. Rendered raw they are
/// a wall of base32 that tells the viewer nothing about who was tagged.
enum NostrMention {

    /// Conformance carrier for the SDK's NIP-19 TLV decoding, which is supplied as a
    /// protocol extension rather than a free function.
    private struct Decoder: MetadataCoding {}
    private static let decoder = Decoder()

    /// `nostr:` followed by an npub or nprofile.
    ///
    /// The trailing class is deliberately loose rather than the exact bech32 alphabet:
    /// it stops at the first character that cannot be part of the token — whitespace or
    /// punctuation — and anything that slips through is rejected by the decoder, which
    /// verifies the checksum. Matching loosely and validating strictly keeps a mention
    /// followed by a comma or newline from being truncated or swallowing what follows.
    private static let mentionRegex = try? NSRegularExpression(
        pattern: "nostr:(npub1[a-z0-9]+|nprofile1[a-z0-9]+)"
    )

    /// Split content into text and mention segments.
    ///
    /// Tokens that fail to decode are left as literal text — a malformed mention should
    /// render as what the author typed, not vanish.
    static func parse(_ content: String) -> [MessageSegment] {
        guard let regex = mentionRegex else { return [.text(content)] }

        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(content)] }

        var segments: [MessageSegment] = []
        var cursor = 0

        for match in matches where match.numberOfRanges > 1 {
            let whole = match.range(at: 0)
            let identifier = ns.substring(with: match.range(at: 1))

            // Undecodable: leave the cursor where it is so the token stays in the next
            // text segment verbatim.
            guard let pubkey = pubkey(fromIdentifier: identifier) else { continue }

            if whole.location > cursor {
                segments.append(.text(ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))))
            }
            segments.append(.mention(pubkey: pubkey, identifier: identifier))
            cursor = whole.location + whole.length
        }

        if cursor < ns.length {
            segments.append(.text(ns.substring(from: cursor)))
        }

        return segments
    }

    /// Someone tagged in a message, and where to look for them.
    struct MentionTarget: Equatable {
        let pubkey: String

        /// Relay hints carried by an `nprofile` (NIP-19 TLV type 1) — the relays where
        /// that person's metadata "is more likely to be found". Empty for `npub`, which
        /// carries no hints at all.
        let relays: [String]
    }

    /// Untrusted input: hints arrive inside chat content written by anyone. Cap how many
    /// relays a single mention can talk us into connecting to.
    private static let maxRelayHints = 4

    /// Everyone mentioned in the content, deduplicated by pubkey.
    static func mentionTargets(in content: String) -> [MentionTarget] {
        var seen = Set<String>()
        var targets: [MentionTarget] = []

        for case .mention(let pubkey, let identifier) in parse(content)
        where seen.insert(pubkey).inserted {
            targets.append(MentionTarget(pubkey: pubkey, relays: relayHints(fromIdentifier: identifier)))
        }

        return targets
    }

    /// Relay hints from an `nprofile`, filtered to websocket URLs.
    ///
    /// The scheme check is not decoration: these strings come from message content, so
    /// anything that is not a relay URL has no business being handed to the relay pool.
    static func relayHints(fromIdentifier identifier: String) -> [String] {
        guard identifier.hasPrefix("nprofile1"),
              let relays = (try? decoder.decodedMetadata(from: identifier))?.relays else {
            return []
        }

        return Array(
            relays
                .filter { $0.hasPrefix("wss://") || $0.hasPrefix("ws://") }
                .prefix(maxRelayHints)
        )
    }

    /// Resolve a bech32 identifier to a hex pubkey, or nil if it does not decode.
    static func pubkey(fromIdentifier identifier: String) -> String? {
        if identifier.hasPrefix("npub1") {
            return PublicKey(npub: identifier)?.hex
        }
        if identifier.hasPrefix("nprofile1") {
            // nprofile is TLV-encoded and carries relay hints alongside the key.
            return (try? decoder.decodedMetadata(from: identifier))?.pubkey
        }
        return nil
    }
}
