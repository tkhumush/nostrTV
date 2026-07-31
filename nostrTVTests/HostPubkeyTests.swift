//
//  HostPubkeyTests.swift
//  nostrTVTests
//
//  Covers resolving the host of a NIP-53 live event (kind 30311) from its tags.
//
//  NIP-53 defines a `p` tag as a participant entry, not specifically the host:
//
//      ["p", "<pubkey>", "<relay-url>", "<role>", "<proof>"]
//
//  with the role being a displayable marker such as Host, Speaker or Participant.
//  Taking the first `p` tag picked a guest on multi-participant streams, which
//  showed the wrong profile and hid the stream from the Following tab.
//

import Testing
import Foundation
import NostrSDK
@testable import nostrTV

struct HostPubkeyTests {

    private static let host = "266815e0c9210dfa324c6cba3573b14bee49da4209a9456f9484e5106cd408a5"
    private static let guest = "1597246ac22f7d1375041054f2a4986bd971d8d196d7997e48973263ac9879ec"
    private static let author = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

    /// Tag has no public memberwise initializer, but it is publicly Decodable,
    /// so tags are built from their wire representation.
    private static func tags(_ raw: [[String]]) throws -> [NostrSDK.Tag] {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([NostrSDK.Tag].self, from: data)
    }

    private static func resolve(_ raw: [[String]]) throws -> String {
        NostrSDKClient.hostPubkey(fromTags: try tags(raw), eventAuthorPubkey: author)
    }

    @Test func prefersTheParticipantMarkedHost() throws {
        // The guest is listed first — the Host marker must still win
        let result = try Self.resolve([
            ["p", Self.guest, "wss://relay.example", "Speaker"],
            ["p", Self.host, "wss://relay.example", "Host"]
        ])
        #expect(result == Self.host)
    }

    @Test func matchesHostMarkerCaseInsensitively() throws {
        let result = try Self.resolve([
            ["p", Self.guest, "", "Participant"],
            ["p", Self.host, "", "host"]
        ])
        #expect(result == Self.host)
    }

    @Test func findsHostMarkerWhenRelayURLIsOmitted() throws {
        // Role slides to an earlier index when the relay URL is absent
        let result = try Self.resolve([
            ["p", Self.guest, "Speaker"],
            ["p", Self.host, "Host"]
        ])
        #expect(result == Self.host)
    }

    @Test func fallsBackToFirstParticipantWhenNoHostMarker() throws {
        let result = try Self.resolve([
            ["p", Self.guest, "wss://relay.example"],
            ["p", Self.host, "wss://relay.example"]
        ])
        #expect(result == Self.guest)
    }

    @Test func fallsBackToEventAuthorWhenNoParticipants() throws {
        // Streams published by the host itself carry no p tag at all
        let result = try Self.resolve([
            ["d", "my-stream"],
            ["status", "live"]
        ])
        #expect(result == Self.author)
    }

    @Test func ignoresNonParticipantTagsWhenLookingForTheHost() throws {
        let result = try Self.resolve([
            ["relays", "wss://one.example", "wss://two.example"],
            ["p", Self.host, "", "Host"]
        ])
        #expect(result == Self.host)
    }
}
