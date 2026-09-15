//
//  NostrMentionTests.swift
//  nostrTVTests
//
//  Covers NIP-27 mention parsing in chat content.
//
//  Chat carries tags as NIP-19 identifiers. Getting this wrong is quietly bad in
//  both directions: a mention that fails to decode leaves base32 on screen, and a
//  regex that matches too greedily eats the punctuation or the words after it.
//

import Testing
import NostrSDK
@testable import nostrTV

struct NostrMentionTests {

    // Canonical NIP-19 vectors: both identifiers below encode the same public key.
    private static let hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    private static let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    private static let nprofile = "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4"
        + "mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"

    @Test func decodesNpub() {
        #expect(NostrMention.pubkey(fromIdentifier: Self.npub) == Self.hex)
    }

    @Test func decodesNprofileTLV() {
        #expect(NostrMention.pubkey(fromIdentifier: Self.nprofile) == Self.hex)
    }

    @Test func parsesMentionSurroundedByText() {
        let segments = NostrMention.parse("hey nostr:\(Self.npub) welcome")
        #expect(segments == [
            .text("hey "),
            .mention(pubkey: Self.hex, identifier: Self.npub),
            .text(" welcome")
        ])
    }

    /// Punctuation directly after a mention is not part of the bech32 token.
    @Test func stopsAtTrailingPunctuation() {
        let segments = NostrMention.parse("thanks nostr:\(Self.npub), appreciated")
        #expect(segments == [
            .text("thanks "),
            .mention(pubkey: Self.hex, identifier: Self.npub),
            .text(", appreciated")
        ])
    }

    @Test func parsesNprofileMention() {
        let segments = NostrMention.parse("cc nostr:\(Self.nprofile)")
        #expect(segments == [
            .text("cc "),
            .mention(pubkey: Self.hex, identifier: Self.nprofile)
        ])
    }

    @Test func handlesMultipleMentions() {
        let segments = NostrMention.parse("nostr:\(Self.npub) and nostr:\(Self.nprofile)")
        #expect(segments == [
            .mention(pubkey: Self.hex, identifier: Self.npub),
            .text(" and "),
            .mention(pubkey: Self.hex, identifier: Self.nprofile)
        ])
    }

    /// A bad checksum must render as what the author typed, not disappear.
    @Test func leavesUndecodableTokenAsText() {
        let broken = "nostr:npub1thisisnotavalidchecksumatall"
        #expect(NostrMention.parse(broken) == [.text(broken)])
    }

    /// The spec vector is short. Real mentions carry relay hints (TLV type 1), which
    /// make the identifier several times longer and add TLV entries after the pubkey.
    @Test func decodesRealWorldNprofileWithRelayHints() throws {
        struct Coder: MetadataCoding {}
        let metadata = Metadata(
            pubkey: Self.hex,
            relays: ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        )
        let identifier = try Coder().encodedIdentifier(with: metadata, identifierType: .profile)

        #expect(NostrMention.pubkey(fromIdentifier: identifier) == Self.hex)
        #expect(NostrMention.parse("hi nostr:\(identifier) there") == [
            .text("hi "),
            .mention(pubkey: Self.hex, identifier: identifier),
            .text(" there")
        ])
    }

    @Test func plainTextIsUntouched() {
        #expect(NostrMention.parse("no mentions here") == [.text("no mentions here")])
    }

    @Test func collectsMentionedPubkeysWithoutDuplicates() {
        let content = "nostr:\(Self.npub) nostr:\(Self.nprofile)"
        #expect(NostrMention.mentionTargets(in: content).map(\.pubkey) == [Self.hex])
    }

    /// The relay hints are the reason nprofile exists instead of npub — dropping them
    /// leaves anyone who is not on the default relays permanently unresolved.
    @Test func keepsRelayHintsFromNprofile() throws {
        struct Coder: MetadataCoding {}
        let hints = ["wss://relay.damus.io", "wss://nos.lol"]
        let identifier = try Coder().encodedIdentifier(
            with: Metadata(pubkey: Self.hex, relays: hints), identifierType: .profile
        )

        #expect(NostrMention.relayHints(fromIdentifier: identifier) == hints)
        #expect(NostrMention.mentionTargets(in: "nostr:\(identifier)") == [
            .init(pubkey: Self.hex, relays: hints)
        ])
    }

    /// An npub carries no hints, and must not invent any.
    @Test func npubHasNoRelayHints() {
        #expect(NostrMention.relayHints(fromIdentifier: Self.npub).isEmpty)
    }

    /// Hints are untrusted input; anything that is not a websocket URL is dropped.
    @Test func rejectsNonWebsocketRelayHints() throws {
        struct Coder: MetadataCoding {}
        let identifier = try Coder().encodedIdentifier(
            with: Metadata(pubkey: Self.hex, relays: ["https://evil.example", "wss://relay.damus.io"]),
            identifierType: .profile
        )

        #expect(NostrMention.relayHints(fromIdentifier: identifier) == ["wss://relay.damus.io"])
    }
}
