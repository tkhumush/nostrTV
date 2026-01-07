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

        // Publish ephemeral profile if we haven't already
        if !keyManager.hasPublishedProfile {
            print("🆕 Publishing ephemeral profile for the first time...")
            do {
                try keyManager.publishEphemeralProfile(using: nostrClient)
            } catch {
                print("⚠️ Failed to publish profile: \(error.localizedDescription)")
            }
        }

        // Update state
        self.currentStream = stream
        self.isWatchingStream = true

        // DISABLED: Presence and chat announcements
        // These features work correctly but may be filtered by streaming services
        // to prevent spam from accounts with no followers.
        //
        // To re-enable, uncomment the code below:

        /*
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

        // Also send a chat message announcing we're watching
        do {
            try await sendJoinChatMessage(stream: stream, aTag: aTag, keyPair: keyPair)
        } catch {
            print("⚠️ Failed to send join chat message: \(error.localizedDescription)")
        }
        */
    }

    // MARK: - Leave Stream

    /// Announce leaving a stream (NIP-53 kind 10312 - Clear Presence)
    /// - Parameters:
    ///   - stream: The stream being left
    func leaveStream(_ stream: Stream) async throws {
        guard let keyPair = keyManager.currentKeyPair else {
            throw LiveActivityError.noKeyPairAvailable
        }

        // Update state
        self.currentStream = nil
        self.isWatchingStream = false

        // DISABLED: Presence clearing
        // To re-enable, uncomment the code below:

        /*
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
        */
    }

    // MARK: - Chat Messages

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
            return
        }

        try await leaveStream(stream)
    }

    /// Update presence periodically to show continued viewing
    /// Should be called every 60 seconds while watching
    func updatePresence() async throws {
        guard let stream = currentStream else {
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

        // DISABLED: Periodic presence updates
        // To re-enable, uncomment the code below:

        /*
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
        */
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

