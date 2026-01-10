import Foundation
import Combine

/// Manages live activity tracking for streams using NIP-53
/// Publishes events when users join or leave streams (bunker-authenticated users only)
@MainActor
class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    private let nostrSDKClient: NostrSDKClient
    private var authManager: NostrAuthManager?

    @Published private(set) var currentStream: Stream?
    @Published private(set) var isWatchingStream: Bool = false

    private init(nostrSDKClient: NostrSDKClient? = nil) {
        if let client = nostrSDKClient {
            self.nostrSDKClient = client
        } else {
            self.nostrSDKClient = try! NostrSDKClient()
        }
        self.authManager = nil
    }

    /// Initialize with custom NostrSDKClient (for dependency injection)
    init(nostrSDKClient: NostrSDKClient, authManager: NostrAuthManager? = nil) {
        self.nostrSDKClient = nostrSDKClient
        self.authManager = authManager
    }

    /// Configure to use an existing NostrSDKClient instance
    func configure(with nostrSDKClient: NostrSDKClient) {
        // Store reference but don't create new connections
        // We'll use the existing client's connections
    }

    // MARK: - Join Stream

    /// Announce joining a stream (NIP-53 kind 10312 - Presence)
    /// Only for bunker-authenticated users
    /// - Parameters:
    ///   - stream: The stream being joined
    func joinStream(_ stream: Stream) async throws {
        guard let streamPubkey = stream.pubkey else {
            throw LiveActivityError.missingStreamPubkey
        }

        // Update state
        self.currentStream = stream
        self.isWatchingStream = true

        // Only publish presence for bunker-authenticated users
        guard let authManager = authManager,
              case .bunker = authManager.authMethod else {
            print("⏭️ Skipping presence announcement - user not authenticated with bunker")
            return
        }

        print("📍 Publishing presence for bunker-authenticated user...")

        // Create the "a" tag referencing the stream event
        // Format: "30311:<stream_author_pubkey>:<d_identifier>"
        let streamDTag = stream.streamID
        let aTag = "30311:\(streamPubkey):\(streamDTag)"

        // Prepare tags for kind 10312 (Presence Event)
        let tags: [[String]] = [
            ["a", aTag]  // Reference to the stream/room
        ]

        // Create unsigned event
        let unsignedEvent = NostrEvent(
            kind: 10312,
            tags: tags,
            id: nil,
            pubkey: nil,
            created_at: Int(Date().timeIntervalSince1970),
            content: "",
            sig: nil
        )

        // Sign with bunker
        let signedEvent = try await authManager.signEvent(unsignedEvent)

        // Publish to relays
        try nostrSDKClient.publishLegacyEvent(signedEvent)

        // Also send a chat message announcing we're watching
        do {
            try await sendJoinChatMessage(stream: stream, aTag: aTag)
        } catch {
            print("⚠️ Failed to send join chat message: \(error.localizedDescription)")
        }
    }

    // MARK: - Leave Stream

    /// Announce leaving a stream (NIP-53 kind 10312 - Clear Presence)
    /// Only for bunker-authenticated users
    /// - Parameters:
    ///   - stream: The stream being left
    func leaveStream(_ stream: Stream) async throws {
        // Update state
        self.currentStream = nil
        self.isWatchingStream = false

        // Only clear presence for bunker-authenticated users
        guard let authManager = authManager,
              case .bunker = authManager.authMethod else {
            print("⏭️ Skipping presence clear - user not authenticated with bunker")
            return
        }

        print("📍 Clearing presence for bunker-authenticated user...")

        // For kind 10312 (replaceable event), leaving means publishing an empty presence
        // event with no 'a' tag, which clears the user's presence from any room

        // Create unsigned event with empty tags
        let unsignedEvent = NostrEvent(
            kind: 10312,
            tags: [],
            id: nil,
            pubkey: nil,
            created_at: Int(Date().timeIntervalSince1970),
            content: "",
            sig: nil
        )

        // Sign with bunker
        let signedEvent = try await authManager.signEvent(unsignedEvent)

        // Publish to relays
        try nostrSDKClient.publishLegacyEvent(signedEvent)
    }

    // MARK: - Chat Messages

    /// Send a chat message announcing joining the stream
    /// - Parameters:
    ///   - stream: The stream being joined
    ///   - aTag: The "a" tag referencing the stream
    private func sendJoinChatMessage(stream: Stream, aTag: String) async throws {
        guard let authManager = authManager else {
            return
        }

        // Prepare tags for kind 1311 (Live Chat Message)
        let tags: [[String]] = [
            ["a", aTag, "", "root"]  // Reference to the stream with "root" marker
        ]

        // Create unsigned event
        let unsignedEvent = NostrEvent(
            kind: 1311,
            tags: tags,
            id: nil,
            pubkey: nil,
            created_at: Int(Date().timeIntervalSince1970),
            content: "watching from nostrTV",
            sig: nil
        )

        // Sign with bunker
        let signedEvent = try await authManager.signEvent(unsignedEvent)

        // Publish to relays
        try nostrSDKClient.publishLegacyEvent(signedEvent)
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
    /// Only for bunker-authenticated users
    func updatePresence() async throws {
        guard let stream = currentStream else {
            return
        }

        guard isWatchingStream else {
            return
        }

        guard let streamPubkey = stream.pubkey else {
            throw LiveActivityError.missingStreamPubkey
        }

        // Only update presence for bunker-authenticated users
        guard let authManager = authManager,
              case .bunker = authManager.authMethod else {
            return
        }

        // Create the "a" tag referencing the stream event
        let streamDTag = stream.streamID
        let aTag = "30311:\(streamPubkey):\(streamDTag)"

        // Prepare tags for kind 10312 (Presence Event)
        let tags: [[String]] = [
            ["a", aTag]  // Reference to the stream/room
        ]

        // Create unsigned event
        let unsignedEvent = NostrEvent(
            kind: 10312,
            tags: tags,
            id: nil,
            pubkey: nil,
            created_at: Int(Date().timeIntervalSince1970),
            content: "",
            sig: nil
        )

        // Sign with bunker
        let signedEvent = try await authManager.signEvent(unsignedEvent)

        // Publish to relays
        try nostrSDKClient.publishLegacyEvent(signedEvent)
    }

    /// Send a chat message to the current stream
    /// - Parameter message: The message to send
    func sendChatMessage(_ message: String) async throws {
        guard let stream = currentStream else {
            throw LiveActivityError.noActiveStream
        }

        // IMPORTANT: Use eventAuthorPubkey (not host pubkey) for a-tag
        // Chat messages must reference: "30311:<event-author-pubkey>:<d-tag>"
        guard let eventAuthorPubkey = stream.eventAuthorPubkey else {
            throw LiveActivityError.missingStreamPubkey
        }

        // Create the "a" tag referencing the stream event
        let streamDTag = stream.streamID
        let aTag = "30311:\(eventAuthorPubkey):\(streamDTag)"

        // Prepare tags for kind 1311 (Live Chat Message)
        var tags: [[String]] = [
            ["a", aTag, "", "root"]  // Reference to the stream
        ]

        // Add stream author as a p tag (use event author, not host)
        tags.append(["p", eventAuthorPubkey])

        // Create unsigned event
        let unsignedEvent = NostrEvent(
            kind: 1311,
            tags: tags,
            id: nil,
            pubkey: nil,
            created_at: Int(Date().timeIntervalSince1970),
            content: message,
            sig: nil
        )

        // Sign using authManager (bunker only)
        guard let authManager = authManager else {
            throw LiveActivityError.noAuthManager
        }

        let signedEvent = try await authManager.signEvent(unsignedEvent)

        // Publish to relays
        try nostrSDKClient.publishLegacyEvent(signedEvent)
    }
}

// MARK: - Errors

enum LiveActivityError: Error, LocalizedError {
    case noAuthManager
    case noActiveStream
    case missingStreamPubkey
    case eventCreationFailed
    case eventPublishFailed

    var errorDescription: String? {
        switch self {
        case .noAuthManager:
            return "No authentication manager available. Please sign in with bunker."
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

