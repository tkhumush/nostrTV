import Foundation
import Combine

/// Manages live activity tracking for streams using NIP-53
/// Publishes events when users join or leave streams
@MainActor
class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    private let nostrClient: NostrClient
    private let keyManager: NostrKeyManager

    @Published private(set) var currentStream: Stream?
    @Published private(set) var isWatchingStream: Bool = false

    private init(nostrClient: NostrClient? = nil) {
        self.nostrClient = nostrClient ?? NostrClient()
        self.keyManager = NostrKeyManager.shared
    }

    /// Initialize with custom NostrClient (for dependency injection)
    init(nostrClient: NostrClient, keyManager: NostrKeyManager = NostrKeyManager.shared) {
        self.nostrClient = nostrClient
        self.keyManager = keyManager
    }

    /// Configure to use an existing NostrClient instance
    func configure(with nostrClient: NostrClient) {
        // Store reference but don't create new connections
        // We'll use the existing client's connections
    }

    // MARK: - Join Stream

    /// Announce joining a stream (NIP-53 kind 10312 - Presence)
    /// - Parameters:
    ///   - stream: The stream being joined
    func joinStream(_ stream: Stream) async throws {
        guard let keyPair = keyManager.currentKeyPair else {
            throw LiveActivityError.noKeyPairAvailable
        }

        guard let streamPubkey = stream.pubkey else {
            throw LiveActivityError.missingStreamPubkey
        }

        // Create the "a" tag referencing the stream event
        // Format: "30311:<stream_author_pubkey>:<d_identifier>"
        let streamDTag = stream.streamID
        let aTag = "30311:\(streamPubkey):\(streamDTag)"

        // Prepare tags for kind 10312 (Presence Event)
        // Kind 10312 is a replaceable event that signals presence in a room
        let tags: [[String]] = [
            ["a", aTag]  // Reference to the stream/room
        ]

        // Content should be empty for presence events
        let content = ""

        // Create and sign the event
        let event = try nostrClient.createSignedEvent(
            kind: 10312,
            content: content,
            tags: tags,
            using: keyPair
        )

        // Publish to relays
        try nostrClient.publishEvent(event)

        // Update state
        self.currentStream = stream
        self.isWatchingStream = true

        print("📡 Published kind 10312 presence event (JOIN) for stream: \(stream.title)")
        print("   Stream ID: \(streamDTag)")
        print("   Event ID: \(event.id ?? "unknown")")
        print("   Pubkey: \(event.pubkey)")
        print("   'a' tag: \(aTag)")
        print("   Timestamp: \(event.created_at)")

        // Also send a chat message announcing we're watching
        do {
            try await sendJoinChatMessage(stream: stream, aTag: aTag, keyPair: keyPair)
        } catch {
            print("❌ Failed to send join chat message: \(error.localizedDescription)")
        }

        // Send a kind 1 note mentioning the stream and tagging the developer
        do {
            try await sendStreamAnnouncement(stream: stream, aTag: aTag, keyPair: keyPair)
        } catch {
            print("❌ Failed to send stream announcement: \(error.localizedDescription)")
        }
    }

    // MARK: - Leave Stream

    /// Announce leaving a stream (NIP-53 kind 10312 - Clear Presence)
    /// - Parameters:
    ///   - stream: The stream being left
    func leaveStream(_ stream: Stream) async throws {
        guard let keyPair = keyManager.currentKeyPair else {
            throw LiveActivityError.noKeyPairAvailable
        }

        // For kind 10312 (replaceable event), leaving means publishing an empty presence
        // event with no 'a' tag, which clears the user's presence from any room

        // Prepare empty tags - no room reference means not present anywhere
        let tags: [[String]] = []

        // Content should be empty
        let content = ""

        // Create and sign the event
        let event = try nostrClient.createSignedEvent(
            kind: 10312,
            content: content,
            tags: tags,
            using: keyPair
        )

        // Publish to relays
        try nostrClient.publishEvent(event)

        // Update state
        self.currentStream = nil
        self.isWatchingStream = false

        print("📡 Published kind 10312 presence event (LEAVE) - cleared presence")
        print("   Event ID: \(event.id ?? "unknown")")
        print("   Pubkey: \(event.pubkey)")
        print("   Tags: [] (empty - clears presence)")
        print("   Timestamp: \(event.created_at)")
    }

    // MARK: - Chat Messages

    /// Send a kind 1 note announcing watching the stream and tagging the developer
    /// - Parameters:
    ///   - stream: The stream being watched
    ///   - aTag: The "a" tag referencing the stream
    ///   - keyPair: Key pair to sign with
    private func sendStreamAnnouncement(stream: Stream, aTag: String, keyPair: NostrKeyPair) async throws {
        // Developer's npub: npub1nje4ghpkjsxe5thcd4gdt3agl2usxyxv3xxyx39ul3xgytl5009q87l02j
        // Converted to hex pubkey
        let developerPubkey = "9cb52a0f494462792ddc5c36b5aec86bec620c646187cc617e5e8fc8aebe1f29"

        // Prepare tags for kind 1 (Text Note)
        // Use indexed "p" tag (NIP-08) for proper mention notification
        let tags: [[String]] = [
            ["p", developerPubkey, "", "mention"],  // Tag the developer with mention marker
            ["a", aTag],                            // Reference to the stream
            ["t", "nostrTV"],                       // Add hashtag
            ["t", "livestream"]                     // Add hashtag
        ]

        // Use nostr:npub reference with #[0] for indexed mention
        let content = "Watching \"\(stream.title)\" on #nostrTV 📺 #[0]"

        // Create and sign the event
        let event = try nostrClient.createSignedEvent(
            kind: 1,
            content: content,
            tags: tags,
            using: keyPair
        )

        // Publish to relays
        try nostrClient.publishEvent(event)

        print("📝 Published kind 1 stream announcement note")
        print("   Event ID: \(event.id ?? "unknown")")
        print("   Content: '\(content)'")
        print("   Tagged: npub1nje4ghpkjsxe5thcd4gdt3agl2usxyxv3xxyx39ul3xgytl5009q87l02j")
    }

    /// Send a chat message announcing joining the stream
    /// - Parameters:
    ///   - stream: The stream being joined
    ///   - aTag: The "a" tag referencing the stream
    ///   - keyPair: Key pair to sign with
    private func sendJoinChatMessage(stream: Stream, aTag: String, keyPair: NostrKeyPair) async throws {
        // Prepare tags for kind 1311 (Live Chat Message)
        // Match the exact NIP-53 structure with only the "a" tag
        let tags: [[String]] = [
            ["a", aTag, "", "root"]  // Reference to the stream with "root" marker
        ]

        let content = "watching from nostrTV"

        // Create and sign the event
        let event = try nostrClient.createSignedEvent(
            kind: 1311,
            content: content,
            tags: tags,
            using: keyPair
        )

        // Publish to relays
        try nostrClient.publishEvent(event)

        print("💬 Published kind 1311 chat message: '\(content)'")
        print("   Event ID: \(event.id ?? "unknown")")
        print("   Pubkey: \(event.pubkey ?? "unknown")")
        print("   Created at: \(event.created_at ?? 0)")
        print("   Tags: \(tags)")
        print("   Content: '\(content)'")
    }

    // MARK: - Convenience Methods

    /// Join stream (using existing NostrClient connections)
    func joinStreamWithConnection(_ stream: Stream) async throws {
        // Use existing NostrClient connections (don't create new ones)
        // Wait a brief moment to ensure any pending connection setup is complete
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        try await joinStream(stream)
    }

    /// Leave current stream if one is active
    func leaveCurrentStream() async throws {
        guard let stream = currentStream else {
            print("⚠️ No active stream to leave")
            return
        }

        try await leaveStream(stream)
    }

    /// Update presence periodically to show continued viewing
    /// Should be called every 60 seconds while watching
    func updatePresence() async throws {
        guard let stream = currentStream else {
            print("⚠️ No active stream for presence update")
            return
        }

        guard isWatchingStream else {
            return
        }

        guard let keyPair = keyManager.currentKeyPair else {
            throw LiveActivityError.noKeyPairAvailable
        }

        guard let streamPubkey = stream.pubkey else {
            throw LiveActivityError.missingStreamPubkey
        }

        // Create the "a" tag referencing the stream event
        let streamDTag = stream.streamID
        let aTag = "30311:\(streamPubkey):\(streamDTag)"

        // Prepare tags for kind 10312 (Presence Event)
        let tags: [[String]] = [
            ["a", aTag]  // Reference to the stream/room
        ]

        // Create and sign the event
        let event = try nostrClient.createSignedEvent(
            kind: 10312,
            content: "",
            tags: tags,
            using: keyPair
        )

        // Publish to relays
        try nostrClient.publishEvent(event)

        print("🔄 Published kind 10312 presence event (UPDATE) - periodic refresh")
    }

    /// Send a chat message to the current stream
    /// - Parameter message: The message to send
    func sendChatMessage(_ message: String) async throws {
        guard let stream = currentStream else {
            throw LiveActivityError.noActiveStream
        }

        guard let keyPair = keyManager.currentKeyPair else {
            throw LiveActivityError.noKeyPairAvailable
        }

        guard let streamPubkey = stream.pubkey else {
            throw LiveActivityError.missingStreamPubkey
        }

        // Create the "a" tag referencing the stream event
        let streamDTag = stream.streamID
        let aTag = "30311:\(streamPubkey):\(streamDTag)"

        // Prepare tags for kind 1311 (Live Chat Message)
        var tags: [[String]] = [
            ["a", aTag, "", "root"]  // Reference to the stream
        ]

        // Add stream author as a p tag
        tags.append(["p", streamPubkey])

        // Create and sign the event
        let event = try nostrClient.createSignedEvent(
            kind: 1311,
            content: message,
            tags: tags,
            using: keyPair
        )

        // Publish to relays
        try nostrClient.publishEvent(event)

        print("💬 Sent chat message to stream: \(stream.title)")
    }
}

// MARK: - Errors

enum LiveActivityError: Error, LocalizedError {
    case noKeyPairAvailable
    case noActiveStream
    case missingStreamPubkey
    case eventCreationFailed
    case eventPublishFailed

    var errorDescription: String? {
        switch self {
        case .noKeyPairAvailable:
            return "No key pair available. Please generate or import keys first."
        case .noActiveStream:
            return "No active stream to interact with."
        case .missingStreamPubkey:
            return "Stream is missing required pubkey field."
        case .eventCreationFailed:
            return "Failed to create Nostr event."
        case .eventPublishFailed:
            return "Failed to publish event to relays."
        }
    }
}

