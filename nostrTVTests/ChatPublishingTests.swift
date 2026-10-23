import Foundation
import Testing
@testable import nostrTV

@MainActor
struct ChatPublishingTests {
    private func stream() -> nostrTV.Stream {
        nostrTV.Stream(streamID: "live:room", eventID: nil, title: "Test",
            streaming_url: "https://example.com/live.m3u8", imageURL: nil,
            pubkey: "host", eventAuthorPubkey: "author", profile: nil,
            status: "live", tags: [], createdAt: Date(), viewerCount: 1,
            recording: nil, startsAt: nil)
    }

    @Test func explicitStreamUsesAnnouncementAuthorAndDoesNotPublishPresence() async throws {
        let client = try RecordingChatClient(relayURLs: [])
        let auth = ChatTestAuth(nostrSDKClient: client, restoreSession: false)
        let manager = LiveActivityManager(nostrSDKClient: client, authManager: auth)
        try await manager.sendChatMessage("Hello", to: stream())

        let event = try #require(client.events.first)
        #expect(client.events.count == 1)
        #expect(event.kind == 1311)
        #expect(event.content == "Hello")
        #expect(event.tags == [["a", "30311:author:live:room", "", "root"], ["p", "author"]])
        #expect(event.sig == "test-signature")
        #expect(manager.currentStream == nil)
        #expect(!manager.isWatchingStream)
    }

    @Test func signingFailureDoesNotPublishAMessage() async throws {
        let client = try RecordingChatClient(relayURLs: [])
        let auth = ChatTestAuth(nostrSDKClient: client, restoreSession: false)
        auth.shouldFail = true
        let manager = LiveActivityManager(nostrSDKClient: client, authManager: auth)
        await #expect(throws: NostrEventError.self) {
            try await manager.sendChatMessage("Hello", to: stream())
        }
        #expect(client.events.isEmpty)
    }

    @Test func tvEntryPointStillRequiresAnActiveStream() async throws {
        let client = try RecordingChatClient(relayURLs: [])
        let manager = LiveActivityManager(nostrSDKClient: client)
        await #expect(throws: LiveActivityError.self) {
            try await manager.sendChatMessage("Hello")
        }
        #expect(client.events.isEmpty)
    }
}

private final class RecordingChatClient: NostrSDKClient {
    var events: [LegacyNostrEvent] = []
    override func publishLegacyEvent(_ event: LegacyNostrEvent) throws { events.append(event) }
}

private final class ChatTestAuth: NostrAuthManager {
    var shouldFail = false
    override func signEvent(_ event: LegacyNostrEvent) async throws -> LegacyNostrEvent {
        if shouldFail { throw NostrEventError.signingFailed }
        var signed = event
        signed.sig = "test-signature"
        return signed
    }
}
