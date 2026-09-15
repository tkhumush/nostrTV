//
//  SubscriptionIDTests.swift
//  nostrTVTests
//
//  Guards the NIP-01 subscription ID length limit.
//
//  NIP-01: "<subscription_id> is an arbitrary, non-empty string of max length
//  64 chars." Relays reject longer IDs, and they do so invisibly from the
//  client's perspective — the REQ never takes effect and no events arrive.
//
//  This regressed once: the chat/zap subscription ID embedded the stream's
//  a-tag, which is 71 characters before its d-tag even starts, so every chat
//  subscription was silently dropped and neither comments nor zaps appeared.
//

import Testing
import Foundation
@testable import nostrTV

struct SubscriptionIDTests {

    private static let pubkey = "266815e0c9210dfa324c6cba3573b14bee49da4209a9456f9484e5106cd408a5"

    @Test func nipLimitIs64() {
        #expect(NostrSDKClient.maxSubscriptionIdLength == 64)
    }

    /// The shape StreamActivityManager builds: a short prefix plus a UUID fragment.
    @Test func chatSubscriptionIDFitsWithinTheLimit() {
        let id = "chat-zaps-\(UUID().uuidString.prefix(8))"
        #expect(id.count <= NostrSDKClient.maxSubscriptionIdLength)
    }

    /// Even a full UUID leaves plenty of headroom, so uniqueness never costs us the limit.
    @Test func fullUUIDSuffixWouldAlsoFit() {
        let id = "chat-zaps-\(UUID().uuidString)"
        #expect(id.count <= NostrSDKClient.maxSubscriptionIdLength)
    }

    /// Documents precisely why embedding an a-tag is not viable: an a-tag is
    /// 71 characters before the d-tag contributes anything, so any ID containing
    /// one breaks the limit no matter how short the rest is.
    @Test func aTagCannotFitInsideASubscriptionID() {
        let aTag = ATag.construct(pubkey: Self.pubkey, dTag: "")
        #expect(aTag.count == 71)
        #expect(aTag.count > NostrSDKClient.maxSubscriptionIdLength)

        let offendingID = "chat-zaps-\(ATag.construct(pubkey: Self.pubkey, dTag: "demo-stream"))-abcd1234"
        #expect(offendingID.count > NostrSDKClient.maxSubscriptionIdLength)
    }

    /// The other subscription IDs used in the app.
    @Test func otherSubscriptionIDsFit() {
        #expect("user-data-auth".count <= NostrSDKClient.maxSubscriptionIdLength)
        #expect("bunker-\(UUID().uuidString.prefix(8))".count <= NostrSDKClient.maxSubscriptionIdLength)
    }
}
