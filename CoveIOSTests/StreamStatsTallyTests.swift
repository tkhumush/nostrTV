import Foundation
import Testing
@testable import CoveIOS

struct StreamStatsTallyTests {
    private let aTag = "30311:host:live"

    private func reaction(_ id: String, from pubkey: String, _ content: String = "+") -> StreamReaction {
        StreamReaction(id: id, senderPubkey: pubkey, content: content, streamATag: aTag, timestamp: Date())
    }

    private func zap(_ id: String, from pubkey: String, sats: Int) -> ZapComment {
        ZapComment(id: id, amount: sats * 1000, senderPubkey: pubkey, senderName: nil, comment: "",
                   timestamp: Date(), streamEventId: aTag, bolt11: nil)
    }

    @Test func likesCountEachPersonOnceAndIgnoreDislikes() {
        var tally = StreamStatsTally()
        tally.record(reaction("1", from: "alice"))
        tally.record(reaction("2", from: "ALICE", "🔥"))
        tally.record(reaction("3", from: "bob", ""))
        tally.record(reaction("4", from: "carol", "-"))
        #expect(tally.likeCount == 2)
    }

    @Test func zapsAreDeduplicatedAndTotalledPerSupporter() {
        var tally = StreamStatsTally()
        tally.record(zap("a", from: "alice", sats: 100))
        tally.record(zap("a", from: "alice", sats: 100))
        tally.record(zap("b", from: "bob", sats: 500))
        tally.record(zap("c", from: "alice", sats: 450))
        tally.record(zap("d", from: "carol", sats: 0))
        #expect(tally.zapCount == 3)
        #expect(tally.zapTotalSats == 1050)
        #expect(tally.topSupporters(2).map(\.pubkey) == ["alice", "bob"])
        #expect(tally.topSupporters(2).first?.sats == 550)
    }
}
