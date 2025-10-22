//
//  ChatManager.swift
//  nostrTV
//
//  Created by Claude Code
//

import Foundation
import Combine

/// Manages live chat messages for streams
/// Subscribes to kind 1311 (live chat) events
@MainActor
class ChatManager: ObservableObject {
    @Published private(set) var messagesByStream: [String: [ChatMessage]] = [:]
    @Published var profileUpdateTrigger: Int = 0  // Triggers UI updates when profiles change

    private let nostrClient: NostrClient
    private var subscriptionIDs: [String: String] = [:]  // streamID -> subscriptionID

    init(nostrClient: NostrClient) {
        self.nostrClient = nostrClient

        // Set up callback to receive chat messages (kind 1311)
        nostrClient.onChatReceived = { [weak self] chatComment in
            Task { @MainActor in
                self?.handleChatMessage(chatComment)
            }
        }

        // Set up callback to detect profile updates
        nostrClient.onProfileReceived = { [weak self] profile in
            Task { @MainActor in
                // Increment trigger to force UI refresh when any profile is received
                self?.profileUpdateTrigger += 1
            }
        }
    }

    /// Fetch chat messages for a specific stream
    func fetchChatMessagesForStream(_ streamEventId: String, pubkey: String, dTag: String) {
        print("💬 Fetching chat messages for stream")
        print("   Event ID: \(streamEventId)")
        print("   D-tag: \(dTag)")
        print("   Pubkey: \(pubkey)")

        // Build the "a" tag reference for the stream
        let aTag = "30311:\(pubkey.lowercased()):\(dTag)"
        print("   A-tag filter: \(aTag)")

        // Create subscription for kind 1311 (live chat) events
        let filter: [String: Any] = [
            "kinds": [1311],
            "#a": [aTag],
            "limit": 15  // Get last 15 messages
        ]

        let subscriptionId = "chat-\(streamEventId.prefix(8))"
        subscriptionIDs[streamEventId] = subscriptionId

        // Send request via NostrClient using REQ format
        let chatReq: [Any] = ["REQ", subscriptionId, filter]

        do {
            try nostrClient.sendRawRequest(chatReq)
            print("   ✓ Chat message request sent to relays with ID: \(subscriptionId)")
        } catch {
            print("   ❌ Failed to fetch chat messages: \(error)")
        }
    }

    /// Handle incoming chat message
    private func handleChatMessage(_ zapComment: ZapComment) {
        guard let streamId = zapComment.streamEventId else {
            print("   ⚠️ Chat message has no stream ID")
            return
        }

        // Convert ZapComment to ChatMessage (don't store senderName, fetch it dynamically)
        let chatMessage = ChatMessage(
            id: zapComment.id,
            senderPubkey: zapComment.senderPubkey,
            message: zapComment.comment,
            timestamp: zapComment.timestamp
        )

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

            print("💬 Added chat message from \(chatMessage.senderPubkey.prefix(8))...")
            print("   Total messages for stream: \(messagesByStream[streamId]!.count)")
        }
    }

    /// Get chat messages for a specific stream
    func getMessagesForStream(_ streamId: String) -> [ChatMessage] {
        return messagesByStream[streamId] ?? []
    }

    /// Clear chat messages for a stream and unsubscribe
    func clearMessagesForStream(_ streamId: String) {
        messagesByStream.removeValue(forKey: streamId)

        // Unsubscribe from chat messages
        if let subscriptionId = subscriptionIDs[streamId] {
            let closeReq: [Any] = ["CLOSE", subscriptionId]
            do {
                try nostrClient.sendRawRequest(closeReq)
                print("💬 Closed chat subscription: \(subscriptionId)")
            } catch {
                print("❌ Failed to close chat subscription: \(error)")
            }
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
