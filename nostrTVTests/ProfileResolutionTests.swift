import Combine
import Foundation
import Testing
@testable import nostrTV

struct ProfileResolutionTests {
    private let pubkey = String(repeating: "a", count: 64)

    private func profile(_ name: String, picture: String? = nil) -> Profile {
        Profile(pubkey: pubkey, name: name, displayName: nil, about: nil,
            picture: picture, nip05: nil, lud16: nil)
    }

    @Test func olderAndDuplicateRelayResponsesCannotEraseAvatar() throws {
        let client = try NostrSDKClient(relayURLs: [])
        let current = profile("Current", picture: "https://example.com/avatar.jpg")
        #expect(client.cacheProfile(current, for: pubkey, createdAt: 200, eventID: "b"))
        #expect(!client.cacheProfile(profile("Old"), for: pubkey, createdAt: 100, eventID: "a"))
        #expect(!client.cacheProfile(current, for: pubkey, createdAt: 200, eventID: "b"))
        #expect(client.getProfile(for: pubkey.uppercased()) == current)
        #expect(!client.cacheProfile(profile("Losing tie"), for: pubkey, createdAt: 200, eventID: "c"))
        #expect(client.cacheProfile(profile("Winning tie"), for: pubkey, createdAt: 200, eventID: "a"))
        #expect(client.getProfile(for: pubkey)?.name == "Winning tie")
        // Actual newer edits, including deliberately removing a picture, must win.
        #expect(client.cacheProfile(profile("New edit"), for: pubkey, createdAt: 300, eventID: "z"))
        #expect(client.getProfile(for: pubkey)?.picture == nil)
    }

    @Test func malformedOptionalMetadataDoesNotDiscardUsefulFields() throws {
        let parsed = try #require(Profile.fromMetadata(pubkey: pubkey, content: """
            {"name":42,"display_name":"  ","displayName":" Good name ","about":{},
             "picture":" https://example.com/avatar.jpg ","nip05":false,"lud16":"host@example.com"}
            """))
        #expect(parsed.preferredName == "Good name")
        #expect(parsed.picture == "https://example.com/avatar.jpg")
        #expect(parsed.lud16 == "host@example.com")
        #expect(Profile.fromMetadata(pubkey: pubkey, content: "[]") == nil)
        #expect(Profile.fromMetadata(pubkey: pubkey, content: "invalid") == nil)
    }

    @Test func emptyNamesFallBackToNameThenDistinctPublicKeys() {
        let blankDisplay = Profile(pubkey: pubkey, name: "  Alice  ", displayName: " \n ",
            about: nil, picture: nil, nip05: nil, lud16: nil)
        #expect(Profile.chatName(profile: blankDisplay, pubkey: pubkey) == "Alice")
        #expect(Profile.chatName(profile: nil, pubkey: pubkey) == "aaaaaaaa…")
        #expect(Profile.chatName(profile: nil, pubkey: "bbbbbbbbcccccccc") == "bbbbbbbb…")
        #expect(Profile.chatName(profile: nil, pubkey: pubkey, fallbackName: " Cached zap name ") == "Cached zap name")
        #expect(Profile.chatName(profile: nil, pubkey: pubkey, fallbackName: " ") == "aaaaaaaa…")
    }

    @Test @MainActor func arrivingProfileRefreshesDiscoverAfterStreamListHasSettled() async throws {
        let client = NostrSDKClient.errorClient(message: "Offline test")
        let viewModel = StreamViewModel(nostrSDKClient: client)
        let stream = Stream(streamID: "test", eventID: nil, title: "Test",
            streaming_url: "https://example.com/live.m3u8", imageURL: nil,
            pubkey: pubkey, eventAuthorPubkey: pubkey, profile: nil, status: "live",
            tags: [], createdAt: Date(), viewerCount: 1, recording: nil, startsAt: nil)
        viewModel.streams = [stream]
        var received = false
        let observation = viewModel.objectWillChange.sink { received = true }
        defer { observation.cancel() }
        let expected = profile("Late arrival", picture: "https://example.com/avatar.jpg")
        client.cacheProfile(expected, for: pubkey, createdAt: 200, eventID: "a")
        for _ in 0..<30 where !received { try await Task.sleep(for: .milliseconds(10)) }
        #expect(received)
        #expect(viewModel.getProfile(for: pubkey) == expected)
        #expect(viewModel.streams.map(\.id) == [stream.id])
    }

    @Test @MainActor func repeatedUnchangedProfilesDoNotKeepInvalidatingViews() async throws {
        let client = try NostrSDKClient(relayURLs: [])
        var changes = 0
        client.addProfileReceivedCallback(forSubscriptionId: "test") { _ in changes += 1 }
        let same = profile("Same name", picture: "https://example.com/avatar.jpg")
        client.cacheProfile(same, for: pubkey, createdAt: 200, eventID: "b")
        for _ in 0..<30 where changes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes == 1)
        client.cacheProfile(same, for: pubkey, createdAt: 200, eventID: "b")
        client.cacheProfile(profile("Old"), for: pubkey, createdAt: 100, eventID: "a")
        client.cacheProfile(same, for: pubkey, createdAt: 300, eventID: "c")
        try await Task.sleep(for: .milliseconds(30))
        #expect(changes == 1)
    }

    @Test @MainActor func signingInUsesAlreadyResolvedMetadataWithoutWaitingForDuplicateEvent() async throws {
        let client = try NostrSDKClient(relayURLs: [])
        defer { client.disconnect(); client.removeCallback(forSubscriptionId: "user-data-auth") }
        let expected = profile("Already resolved", picture: "https://example.com/avatar.jpg")
        client.cacheProfile(expected, for: pubkey, createdAt: 200, eventID: "a")
        // Let the original arrival finish before registering the new consumer.
        try await Task.sleep(for: .milliseconds(20))
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: "nostrUserProfile")
        defer {
            if let original { defaults.set(original, forKey: "nostrUserProfile") }
            else { defaults.removeObject(forKey: "nostrUserProfile") }
        }
        let auth = NostrAuthManager(nostrSDKClient: client, restoreSession: false)
        auth.currentUser = UserSession(nip05: "", hexPubkey: pubkey)
        auth.fetchUserData()
        #expect(auth.currentProfile == expected)
        #expect(!auth.isLoadingProfile)
    }

    @Test @MainActor func lateMentionProfileRefreshesChatEvenWhenItIsNotASender() async throws {
        let client = try NostrSDKClient(relayURLs: [])
        let activity = StreamActivityManager()
        let stream = Stream(streamID: "test", eventID: nil, title: "Test", streaming_url: "https://example.com/live.m3u8",
            imageURL: nil, pubkey: pubkey, eventAuthorPubkey: pubkey, profile: nil, status: "live",
            tags: [], createdAt: Date(), viewerCount: 1, recording: nil, startsAt: nil)
        activity.startListening(for: stream, using: client)
        defer { activity.stopListening() }
        let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
        let target = try #require(NostrMention.pubkey(fromIdentifier: npub))
        activity.addLocalMessage(ChatMessage(id: "test", senderPubkey: pubkey,
            message: "Hello nostr:\(npub)", timestamp: Date()))
        let before = activity.updateTrigger
        let mentioned = Profile(pubkey: target, name: "Mentioned person", displayName: nil, about: nil,
            picture: nil, nip05: nil, lud16: nil)
        client.cacheProfile(mentioned, for: target, createdAt: 200, eventID: "a")
        for _ in 0..<30 where activity.updateTrigger == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(activity.updateTrigger > before)
        #expect(activity.chatMessages.count == 1)
    }
}
