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

    private init() {
        self.nostrClient = NostrClient()
        self.keyManager = NostrKeyManager.shared
    }

    /// Initialize with custom NostrClient (for dependency injection)
    init(nostrClient: NostrClient, keyManager: NostrKeyManager = NostrKeyManager.shared) {
        self.nostrClient = nostrClient
        self.keyManager = keyManager
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

        print("📡 Published presence event for stream: \(stream.title)")
        print("   Stream ID: \(streamDTag)")
        print("   Event ID: \(event.id ?? "unknown")")
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

        print("📡 Published leave presence event (cleared presence)")
        print("   Event ID: \(event.id ?? "unknown")")
    }

    // MARK: - Convenience Methods

    /// Join stream and automatically connect NostrClient to relays if needed
    func joinStreamWithConnection(_ stream: Stream) async throws {
        // Ensure NostrClient is connected (always connect to be safe)
        nostrClient.connect()
        // Wait a moment for connections to establish
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

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
    /// Should be called every 30-60 seconds while watching
    func updatePresence() async throws {
        guard let stream = currentStream else {
            print("⚠️ No active stream for presence update")
            return
        }

        guard isWatchingStream else {
            return
        }

        // Re-publish the presence event (kind 10312 is replaceable)
        try await joinStream(stream)
        print("🔄 Updated presence for stream: \(stream.title)")
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

