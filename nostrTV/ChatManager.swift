//
//  ChatManager.swift
//  nostrTV
//
//  Created by Claude Code
//  Refactored: 2026-01-07 to use NostrSDK
//

import Foundation
import Combine
import NostrSDK

/// Manages live chat messages for streams
/// Subscribes to kind 1311 (live chat) events using NostrSDK
@MainActor
class ChatManager: ObservableObject {
    @Published private(set) var messagesByStream: [String: [ChatMessage]] = [:]
    @Published var profileUpdateTrigger: Int = 0  // Triggers UI updates when profiles change
    @Published var messageUpdateTrigger: Int = 0  // Triggers UI updates when messages change

    private let nostrClient: NostrSDKClient
    private var subscriptionIDs: [String: String] = [:]  // aTag -> subscriptionID (use aTag for consistent key management)

    init(nostrClient: NostrSDKClient) {
        self.nostrClient = nostrClient

        // Set up callback to receive chat messages (kind 1311)
        nostrClient.onChatReceived = { [weak self] chatComment in
            Task { @MainActor in
                self?.handleChatMessage(chatComment)
            }
        }

        // Set up callback to detect profile updates
        nostrClient.addProfileReceivedCallback { [weak self] profile in
            Task { @MainActor in
                // Increment trigger to force UI refresh when any profile is received
                self?.profileUpdateTrigger += 1
            }
        }
    }

    /// Fetch chat messages for a specific stream
    func fetchChatMessagesForStream(_ streamEventId: String, pubkey: String, dTag: String) {
        // Build the "a" tag reference for the stream (normalized to lowercase)
        // IMPORTANT: Use aTag as the canonical key for subscriptions and storage
        let aTag = "30311:\(pubkey.lowercased()):\(dTag)"

        print("🔍 ChatManager: Subscribing to chat for \(dTag)")

        // Close any existing subscription for this stream to prevent conflicts
        if let existingSubscriptionId = subscriptionIDs[aTag] {
            nostrClient.closeSubscription(existingSubscriptionId)
            subscriptionIDs.removeValue(forKey: aTag)
        }

        // Create SDK Filter for kind 1311 (live chat) events
        guard let filter = Filter(
            kinds: [1311],
            tags: ["a": [aTag]],
            limit: 15  // Get last 15 messages
        ) else {
            print("❌ ChatManager: Failed to create chat filter")
            return
        }

        // Ensure relays are connected
        nostrClient.connect()

        // Subscribe with a short delay to allow connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            let subscriptionId = self.nostrClient.subscribe(
                with: filter,
                purpose: "chat-\(streamEventId.prefix(8))"
            )

            // Store under aTag key for consistent lookup
            self.subscriptionIDs[aTag] = subscriptionId
        }
    }

    /// Handle incoming chat message
    private func handleChatMessage(_ zapComment: ZapComment) {
        guard let rawStreamId = zapComment.streamEventId else {
            print("⚠️ ChatManager: Received chat message with nil streamEventId - DROPPING")
            return
        }

        // Normalize the storage key to ensure consistent lookup
        // The aTag format is "30311:<pubkey>:<d-tag>" - normalize pubkey to lowercase
        let streamId = normalizeATag(rawStreamId)

        print("💬 ChatManager: Received message: \(zapComment.comment.prefix(40))...")

        // Convert ZapComment to ChatMessage (don't store senderName, fetch it dynamically)
        let chatMessage = ChatMessage(
            id: zapComment.id,
            senderPubkey: zapComment.senderPubkey,
            message: zapComment.comment,
            timestamp: zapComment.timestamp
        )

        // Request profile for this sender if we don't have it yet
        if nostrClient.getProfile(for: zapComment.senderPubkey) == nil {
            nostrClient.requestProfile(for: zapComment.senderPubkey)
        }

        // Add to messages array for this stream
        // Use copy-modify-reassign pattern to trigger @Published updates
        var messages = messagesByStream[streamId] ?? []

        // Check if message already exists (prevent duplicates)
        if !messages.contains(where: { $0.id == chatMessage.id }) {
            messages.append(chatMessage)

            // Sort by timestamp (oldest first, newest at bottom)
            messages.sort { $0.timestamp < $1.timestamp }

            // Keep only last 15 messages
            if messages.count > 15 {
                messages.removeFirst()
            }

            // Reassign to trigger @Published notification
            messagesByStream[streamId] = messages

            print("✅ ChatManager: Message stored. Total: \(messages.count)")

            // Trigger UI update
            messageUpdateTrigger += 1
        } else {
            print("⚠️ ChatManager: Duplicate message, skipping")
        }
    }

    /// Normalize aTag to ensure consistent lookup
    /// Converts the pubkey portion to lowercase: "30311:PUBKEY:dtag" -> "30311:pubkey:dtag"
    private func normalizeATag(_ aTag: String) -> String {
        let parts = aTag.split(separator: ":", maxSplits: 2)
        guard parts.count >= 3 else {
            // Not a valid aTag format, return as-is (lowercased for safety)
            return aTag.lowercased()
        }

        let kind = parts[0]
        let pubkey = parts[1].lowercased()
        let dTag = parts[2]

        return "\(kind):\(pubkey):\(dTag)"
    }

    /// Get chat messages for a specific stream
    func getMessagesForStream(_ streamId: String) -> [ChatMessage] {
        return messagesByStream[streamId] ?? []
    }

    /// Clear chat messages for a stream and unsubscribe
    func clearMessagesForStream(_ streamId: String) {
        messagesByStream.removeValue(forKey: streamId)

        // Unsubscribe from chat messages using NostrSDKClient
        if let subscriptionId = subscriptionIDs[streamId] {
            nostrClient.closeSubscription(subscriptionId)
            subscriptionIDs.removeValue(forKey: streamId)
        }
    }
}

/// Represents a chat message in a live stream
struct ChatMessage: Identifiable {
    let id: String
    let senderPubkey: String
    let message: String
    let timestamp: Date
}
