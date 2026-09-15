//
//  ATagTests.swift
//  nostrTVTests
//
//  Covers NIP-33 a-tag construction, normalization and parsing.
//
//  These matter because a-tags are compared across sources: a stream's own
//  coordinate (`Stream.aTag`) versus the coordinate carried by a kind 5 deletion
//  event. If the two sides normalize differently, deletions silently fail to
//  match and a deleted stream stays visible.
//

import Testing
@testable import nostrTV

struct ATagTests {

    private static let pubkey = "266815e0c9210dfa324c6cba3573b14bee49da4209a9456f9484e5106cd408a5"
    private static let upperPubkey = pubkey.uppercased()

    // MARK: - construct

    @Test func constructUsesLiveEventKindByDefault() {
        #expect(ATag.construct(pubkey: Self.pubkey, dTag: "my-stream")
                == "30311:\(Self.pubkey):my-stream")
    }

    @Test func constructLowercasesPubkey() {
        #expect(ATag.construct(pubkey: Self.upperPubkey, dTag: "my-stream")
                == "30311:\(Self.pubkey):my-stream")
    }

    @Test func constructPreservesDTagCase() {
        // d-tags are opaque identifiers and must not be case-folded
        #expect(ATag.construct(pubkey: Self.pubkey, dTag: "My-Stream")
                .hasSuffix(":My-Stream"))
    }

    // MARK: - normalize

    @Test func normalizeLowercasesOnlyThePubkey() {
        let input = "30311:\(Self.upperPubkey):My-Stream"
        #expect(ATag.normalize(input) == "30311:\(Self.pubkey):My-Stream")
    }

    @Test func normalizeIsIdempotent() {
        let once = ATag.normalize("30311:\(Self.upperPubkey):My-Stream")
        #expect(ATag.normalize(once) == once)
    }

    @Test func normalizeKeepsDTagsContainingColons() {
        // maxSplits: 2 means a colon inside the d-tag must survive intact
        let input = "30311:\(Self.pubkey):id:with:colons"
        #expect(ATag.normalize(input) == input)
    }

    @Test func normalizeFallsBackToLowercasingMalformedInput() {
        #expect(ATag.normalize("NOT-AN-ATAG") == "not-an-atag")
    }

    // MARK: - parse

    @Test func parseReturnsComponents() {
        let parsed = ATag.parse("30311:\(Self.pubkey):my-stream")
        #expect(parsed?.kind == 30311)
        #expect(parsed?.pubkey == Self.pubkey)
        #expect(parsed?.dTag == "my-stream")
    }

    @Test func parseLowercasesPubkey() {
        #expect(ATag.parse("30311:\(Self.upperPubkey):my-stream")?.pubkey == Self.pubkey)
    }

    @Test func parseRejectsNonHexLengthPubkey() {
        #expect(ATag.parse("30311:tooshort:my-stream") == nil)
    }

    @Test func parseRejectsNonNumericKind() {
        #expect(ATag.parse("abc:\(Self.pubkey):my-stream") == nil)
    }

    @Test func parseRejectsMissingComponents() {
        #expect(ATag.parse("30311:\(Self.pubkey)") == nil)
    }

    // MARK: - cross-source matching (the bug this consolidation fixed)

    @Test func deletionCoordinateMatchesStreamCoordinateAcrossCasing() {
        // A relay may deliver the deletion coordinate with a differently-cased
        // pubkey than the stream event. Both sides go through ATag, so they match.
        let streamSide = ATag.construct(pubkey: Self.upperPubkey, dTag: "my-stream")
        let deletionSide = ATag.normalize("30311:\(Self.pubkey):my-stream")
        #expect(streamSide == deletionSide)
    }
}
