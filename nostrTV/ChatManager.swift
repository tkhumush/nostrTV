//
//  ChatManager.swift
//  nostrTV
//
//  Created by Claude Code
//  Refactored: 2026-01-15 to match ZapManager's simple, reliable pattern
//

import Foundation
import Combine
import NostrSDK

/// Manages live chat messages for streams
/// Follows the same simple pattern as ZapManager - direct raw requests, no complex routing
@MainActor
class ChatManager: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var profileUpdateTrigger: Int = 0
    @Published var messageUpdateTrigger: Int = 0

    private var nostrClient: NostrSDKClient?
    private var subscriptionId: String?
    private var currentStreamATag: String?

    /// Maximum messages to keep
    private let maxMessages = 50

    init() {
        print("💬 ChatManager: Initialized")
    }

    deinit {
        print("💬 ChatManager: Deallocating")
    }

    // MARK: - Public Methods

    /// Start listening for chat messages for a stream
    /// - Parameters:
    ///   - stream: The stream to listen for
    ///   - client: The NostrSDKClient for profile lookups and requests
    func startListening(for stream: Stream, using client: NostrSDKClient) {
        guard let authorPubkey = stream.eventAuthorPubkey else {
            print("💬 ChatManager: Cannot start - stream has no eventAuthorPubkey")
            return
        }

        self.nostrClient = client
        self.currentStreamATag = "30311:\(authorPubkey.lowercased()):\(stream.streamID)"

        // Close any existing subscription first
        closeSubscription()

        // Set up callback DIRECTLY on the client (same pattern as ZapManager)
        client.onChatReceived = { [weak self] chatComment in
            Task { @MainActor in
                self?.handleChatReceived(chatComment)
            }
        }

        // Set up profile update callback
        client.addProfileReceivedCallback { [weak self] _ in
            Task { @MainActor in
                self?.profileUpdateTrigger += 1
            }
        }

        // Create subscription ID
        subscriptionId = "chat-\(stream.streamID.prefix(8))-\(UUID().uuidString.prefix(4))"

        print("💬 ChatManager: Starting to listen for \(stream.streamID)")
        print("   aTag: \(currentStreamATag ?? "nil")")
        print("   subscriptionId: \(subscriptionId ?? "nil")")

        // Build filter for kind 1311 (live chat messages)
        // Filter by "a" tag to get messages for this specific stream
        let filter: [String: Any] = [
            "kinds": [1311],
            "#a": [currentStreamATag!],
            "limit": 50
        ]

        let chatReq: [Any] = ["REQ", subscriptionId!, filter]

        print("   Chat filter:")
        print("     kinds: [1311]")
        print("     #a: [\(currentStreamATag!)]")
        print("     limit: 50")

        // Send request via raw request (same as ZapManager)
        do {
            try client.sendRawRequest(chatReq)
            print("   ✓ Chat request sent to relays")
        } catch {
            print("   ❌ Failed to send chat request: \(error)")
        }
    }

    /// Stop listening - explicitly closes the subscription
    func stopListening() {
        print("💬 ChatManager: Stopping")
        closeSubscription()
        messages = []
        currentStreamATag = nil
    }

    /// Get messages for the current stream (for compatibility)
    func getMessagesForStream(_ streamId: String) -> [ChatMessage] {
        return messages
    }

    // MARK: - Private Methods

    /// Close the current subscription
    private func closeSubscription() {
        guard let subId = subscriptionId, let client = nostrClient else {
            return
        }

        // Send CLOSE message (same pattern as ZapManager)
        let closeReq: [Any] = ["CLOSE", subId]
        do {
            try client.sendRawRequest(closeReq)
            print("📪 Closed chat subscription: \(subId)")
        } catch {
            print("❌ Failed to close chat subscription: \(error)")
        }

        subscriptionId = nil
    }

    /// Handle a received chat message (kind 1311)
    private func handleChatReceived(_ chatComment: ZapComment) {
        // Validate the message is for our stream
        guard let messageATag = chatComment.streamEventId else {
            print("💬 ChatManager: Message has no streamEventId, ignoring")
            return
        }

        // Check if this message is for our current stream
        let normalizedMessageATag = normalizeATag(messageATag)
        guard let ourATag = currentStreamATag, normalizedMessageATag == ourATag else {
            // Message is for a different stream, ignore
            return
        }

        print("💬 ChatManager: Received message for our stream: \(chatComment.comment.prefix(30))...")

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

        // Check for duplicates
        guard !messages.contains(where: { $0.id == message.id }) else {
            print("💬 ChatManager: Duplicate message, skipping")
            return
        }

        // Add and sort
        messages.append(message)
        messages.sort { $0.timestamp < $1.timestamp }

        // Trim to max
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }

        print("💬 ChatManager: Message stored. Total: \(messages.count)")

        // Trigger UI update
        messageUpdateTrigger += 1
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
