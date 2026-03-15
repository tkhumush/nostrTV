//
//  StreamActivityManager.swift
//  nostrTV
//
//  Created by Claude Code
//  Combines chat (kind 1311) and zap receipts (kind 9735) into a single subscription
//

import Foundation

/// Manages live chat messages and zap receipts for a stream with a single subscription
/// Uses #a tag filtering to get both kinds in one request
@MainActor
class StreamActivityManager: ObservableObject {
    @Published private(set) var chatMessages: [ChatMessage] = []
    @Published private(set) var zapComments: [ZapComment] = []
    @Published var updateTrigger: Int = 0  // Triggers UI updates

    private var nostrClient: NostrSDKClient?
    private var subscriptionId: String?
    private var currentStreamATag: String?

    /// Maximum messages/zaps to keep
    private let maxMessages = 50
    private let maxZaps = 50

    init() {
        print("📺 StreamActivityManager: Initialized")
    }

    deinit {
        print("📺 StreamActivityManager: Deallocating")
    }

    // MARK: - Public Methods

    /// Start listening for chat and zaps for a stream
    /// - Parameters:
    ///   - stream: The stream to listen for
    ///   - client: The NostrSDKClient for requests
    func startListening(for stream: Stream, using client: NostrSDKClient) {
        guard let authorPubkey = stream.eventAuthorPubkey else {
            print("📺 StreamActivityManager: Cannot start - stream has no eventAuthorPubkey")
            return
        }

        self.nostrClient = client
        self.currentStreamATag = "30311:\(authorPubkey.lowercased()):\(stream.streamID)"

        // Close any existing subscription first
        closeSubscription()

        // Clear existing data
        chatMessages = []
        zapComments = []

        // Remove any previous callbacks before adding new ones
        client.removeActivityCallbacks()

        // Set up callbacks for both chat and zaps (array-based, no overwriting)
        client.addChatReceivedCallback { [weak self] chatComment in
            Task { @MainActor in
                self?.handleChatReceived(chatComment)
            }
        }

        client.addZapReceivedCallback { [weak self] zapComment in
            Task { @MainActor in
                self?.handleZapReceived(zapComment)
            }
        }

        // Listen for profile arrivals so the UI updates when profiles load
        client.addProfileReceivedCallback { [weak self] profile in
            Task { @MainActor in
                self?.handleProfileReceived(profile)
            }
        }

        // Subscribe to both kinds with a single request using the new helper
        subscriptionId = client.subscribeToChatAndZaps(aTag: currentStreamATag!)

        print("📺 StreamActivityManager: Started listening for \(stream.streamID)")
        print("   aTag: \(currentStreamATag ?? "nil")")
        print("   subscriptionId: \(subscriptionId ?? "nil")")
    }

    /// Stop listening - closes the subscription and clears data
    func stopListening() {
        print("📺 StreamActivityManager: Stopping")
        closeSubscription()
        nostrClient?.removeActivityCallbacks()
        chatMessages = []
        zapComments = []
        currentStreamATag = nil
    }

    /// Get profile for a pubkey (convenience method)
    func getProfile(for pubkey: String) -> Profile? {
        return nostrClient?.getProfile(for: pubkey)
    }

    /// Add a locally-sent message (optimistic self-echo)
    func addLocalMessage(_ message: ChatMessage) {
        // Check for duplicates
        guard !chatMessages.contains(where: { $0.id == message.id }) else { return }

        chatMessages.append(message)
        chatMessages.sort { $0.timestamp < $1.timestamp }

        if chatMessages.count > maxMessages {
            chatMessages.removeFirst(chatMessages.count - maxMessages)
        }

        updateTrigger += 1
    }

    // MARK: - Private Methods

    /// Close the current subscription
    private func closeSubscription() {
        guard let subId = subscriptionId, let client = nostrClient else {
            return
        }

        client.closeSubscription(subId)
        print("📪 StreamActivityManager: Closed subscription \(subId.prefix(8))...")
        subscriptionId = nil
    }

    /// Handle a received chat message (kind 1311)
    private func handleChatReceived(_ chatComment: ZapComment) {
        // Validate the message is for our stream
        guard let messageATag = chatComment.streamEventId else {
            return
        }

        // Check if this message is for our current stream
        let normalizedMessageATag = normalizeATag(messageATag)
        guard let ourATag = currentStreamATag, normalizedMessageATag == ourATag else {
            return
        }

        // Convert to ChatMessage
        let message = ChatMessage(
            id: chatComment.id,
            senderPubkey: chatComment.senderPubkey,
            message: chatComment.comment,
            timestamp: chatComment.timestamp
        )

        // Request profile if not cached
        if let client = nostrClient, client.getProfile(for: chatComment.senderPubkey) == nil {
            client.requestProfile(for: chatComment.senderPubkey)
        }

        // Check for duplicates (by ID or by matching sender+content for optimistic echoes)
        if let existingIndex = chatMessages.firstIndex(where: {
            $0.id == message.id ||
            ($0.senderPubkey == message.senderPubkey && $0.message == message.message &&
             abs($0.timestamp.timeIntervalSince(message.timestamp)) < 60)
        }) {
            // Replace optimistic message with the real one (has correct Nostr event ID)
            chatMessages[existingIndex] = message
            updateTrigger += 1
            return
        }

        // Add and sort (newest at end for chat)
        chatMessages.append(message)
        chatMessages.sort { $0.timestamp < $1.timestamp }

        // Trim to max (remove oldest)
        if chatMessages.count > maxMessages {
            chatMessages.removeFirst(chatMessages.count - maxMessages)
        }

        // Trigger UI update
        updateTrigger += 1
    }

    /// Handle a received zap receipt (kind 9735)
    private func handleZapReceived(_ zapComment: ZapComment) {
        // Validate the zap is for our stream
        guard let zapATag = zapComment.streamEventId else {
            return
        }

        // Check if this zap is for our current stream
        let normalizedZapATag = normalizeATag(zapATag)
        guard let ourATag = currentStreamATag, normalizedZapATag == ourATag else {
            return
        }

        // Request profile if not cached
        if let client = nostrClient, client.getProfile(for: zapComment.senderPubkey) == nil {
            client.requestProfile(for: zapComment.senderPubkey)
        }

        // Check for duplicates
        guard !zapComments.contains(where: { $0.id == zapComment.id }) else {
            return
        }

        // Add and sort (newest first for zaps)
        zapComments.append(zapComment)
        zapComments.sort { $0.timestamp > $1.timestamp }

        // Trim to max (remove oldest)
        if zapComments.count > maxZaps {
            zapComments = Array(zapComments.prefix(maxZaps))
        }

        // Trigger UI update
        updateTrigger += 1
    }

    /// Handle a profile arrival - trigger UI update if the profile belongs to a chat/zap sender
    private func handleProfileReceived(_ profile: Profile) {
        let pubkey = profile.pubkey
        let isRelevant = chatMessages.contains { $0.senderPubkey == pubkey }
            || zapComments.contains { $0.senderPubkey == pubkey }

        if isRelevant {
            updateTrigger += 1
        }
    }

    /// Normalize aTag for consistent comparison
    private func normalizeATag(_ aTag: String) -> String {
        let parts = aTag.split(separator: ":", maxSplits: 2)
        guard parts.count >= 3 else {
            return aTag.lowercased()
        }

        let kind = parts[0]
        let pubkey = parts[1].lowercased()
        let dTag = parts[2]

        return "\(kind):\(pubkey):\(dTag)"
    }
}

/// Represents a chat message in a live stream
struct ChatMessage: Identifiable {
    let id: String
    let senderPubkey: String
    let message: String
    let timestamp: Date
}
