//
//  ATag.swift
//  nostrTV
//
//  Single source of truth for NIP-33 addressable event coordinates ("a" tags).
//
//  An a-tag has the form `<kind>:<pubkey>:<d-tag>`, e.g.
//  `30311:266815e0c9210dfa324c6cba3573b14bee49da4209a9456f9484e5106cd408a5:my-stream`.
//
//  These strings are compared across sources — a stream event's own coordinate
//  versus the coordinate carried by a kind 5 deletion — so both sides must be
//  normalized identically or the comparison silently fails. Hex pubkeys are
//  case-insensitive, so normalization lowercases the pubkey while leaving the
//  d-tag untouched (d-tags are opaque and case-sensitive).
//

import Foundation

/// Utilities for building, normalizing and parsing NIP-33 a-tags.
enum ATag {

    /// Kind for NIP-53 live events.
    static let liveEventKind = 30311

    /// Build a normalized a-tag from its components.
    static func construct(pubkey: String, dTag: String, kind: Int = liveEventKind) -> String {
        "\(kind):\(pubkey.lowercased()):\(dTag)"
    }

    /// Normalize an a-tag for consistent comparison and dictionary lookups.
    ///
    /// Lowercases the pubkey component only. Malformed input is returned
    /// lowercased whole, matching the previous behaviour of the call sites this
    /// consolidates.
    static func normalize(_ aTag: String) -> String {
        let parts = aTag.split(separator: ":", maxSplits: 2)
        guard parts.count >= 3 else { return aTag.lowercased() }
        return "\(parts[0]):\(parts[1].lowercased()):\(parts[2])"
    }

    /// Parse an a-tag into its components, validating the pubkey is 64 hex chars.
    /// - Returns: The components with a lowercased pubkey, or nil if malformed.
    static func parse(_ aTag: String) -> (kind: Int, pubkey: String, dTag: String)? {
        let parts = aTag.split(separator: ":", maxSplits: 2)
        guard parts.count >= 3,
              let kind = Int(parts[0]),
              parts[1].count == 64 else {
            return nil
        }
        return (kind, String(parts[1]).lowercased(), String(parts[2]))
    }
}
