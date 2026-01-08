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
    private var subscriptionIDs: [String: String] = [:]  // streamID -> subscriptionID

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
        // Build the "a" tag reference for the stream
        let aTag = "30311:\(pubkey.lowercased()):\(dTag)"

        // Create SDK Filter for kind 1311 (live chat) events
        guard let filter = Filter(
            kinds: [1311],
            tags: ["a": [aTag]],
            limit: 15  // Get last 15 messages
        ) else {
            print("❌ ChatManager: Failed to create chat filter")
            return
        }

        // IMPORTANT: Wait for relays to connect before subscribing
        // The SDK needs time to establish WebSocket connections
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            let subscriptionId = self.nostrClient.subscribe(
                with: filter,
                purpose: "chat-\(streamEventId.prefix(8))"
            )

            self.subscriptionIDs[streamEventId] = subscriptionId
        }
    }

    /// Handle incoming chat message
    private func handleChatMessage(_ zapComment: ZapComment) {
        guard let streamId = zapComment.streamEventId else {
            return
        }

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
        if messagesByStream[streamId] == nil {
            messagesByStream[streamId] = []
        }

        // Check if message already exists (prevent duplicates)
        if !messagesByStream[streamId]!.contains(where: { $0.id == chatMessage.id }) {
            messagesByStream[streamId]!.append(chatMessage)

            // Sort by timestamp (oldest first, newest at bottom)
            messagesByStream[streamId]!.sort { $0.timestamp < $1.timestamp }

            // Keep only last 15 messages
            if messagesByStream[streamId]!.count > 15 {
                messagesByStream[streamId]!.removeFirst()
            }

            // Trigger UI update
            messageUpdateTrigger += 1
        }
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
