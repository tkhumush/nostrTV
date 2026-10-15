import Testing
import Foundation
@testable import nostrTV

struct CovePresentationTests {
    @Test func liveUpdatesDoNotReorderVisibleCards() {
        var order = CoveStreamOrder()
        order.reconcile(["a", "b", "c"])
        order.reconcile(["c", "b", "a", "d"])
        #expect(order.ids == ["a", "b", "c", "d"])
    }

    @Test func endedSlotsAreRemovedAndNewStreamsAppendOnce() {
        var order = CoveStreamOrder()
        order.reconcile(["a", "b", "b"])
        order.reconcile(["c", "b", "c"])
        #expect(order.ids == ["b", "c"])
        order.reconcile([])
        #expect(order.ids.isEmpty)
    }

    @Test func attachingProfilePreservesPlaybackAndChatCoordinates() {
        let stream = Stream(streamID: "live", eventID: "event", title: "Live stream",
            streaming_url: "https://example.com/live.m3u8", imageURL: "https://example.com/art.jpg",
            pubkey: "host", eventAuthorPubkey: "author", profile: nil, status: "live", tags: ["music"],
            createdAt: Date(), viewerCount: 20, recording: "https://example.com/replay.m3u8",
            startsAt: Date(), relays: ["wss://stream.example"])
        let profile = Profile(pubkey: "host", name: "Host", displayName: nil, about: nil, picture: nil, nip05: nil, lud16: "host@example.com")
        let enriched = stream.attachingProfile(profile)
        #expect(enriched.profile == profile)
        #expect(enriched.relays == stream.relays)
        #expect(enriched.aTag == stream.aTag)
        #expect(enriched.streaming_url == stream.streaming_url)
        #expect(enriched.recording == stream.recording)
        #expect(enriched.startsAt == stream.startsAt)
        #expect(enriched.attachingProfile(nil).profile == profile)
    }
}
