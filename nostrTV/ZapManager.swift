//
//  ZapManager.swift
//  nostrTV
//
//  Created by Claude Code
//

import Foundation

/// Manages zap comments for streams
/// Fetches and stores the latest zap receipts for each stream
class ZapManager: ObservableObject {
    @Published var zapComments: [String: [ZapComment]] = [:] // streamEventId -> [ZapComment]

    private let nostrClient: NostrClient
    private var subscriptionIds: Set<String> = []
    private var currentStreamEventId: String?  // Track current stream event ID
    private var currentStreamATag: String?     // Track current stream "a" tag

    init(nostrClient: NostrClient) {
        self.nostrClient = nostrClient

        // Set up callback to receive zap receipts
        nostrClient.onZapReceived = { [weak self] zapComment in
            self?.handleZapReceived(zapComment)
        }
    }

    /// Fetch zap comments for a specific stream
    /// - Parameters:
    ///   - streamEventId: The event ID of the stream
    ///   - streamPubkey: The pubkey of the stream creator (for "a" tag)
    ///   - streamDTag: The "d" tag identifier (for "a" tag)
    func fetchZapsForStream(_ streamEventId: String, pubkey: String? = nil, dTag: String? = nil) {
        // Store the stream info for filtering
        currentStreamEventId = streamEventId.lowercased()
        if let pubkey = pubkey, let dTag = dTag {
            currentStreamATag = "30311:\(pubkey.lowercased()):\(dTag)"
        } else {
            currentStreamATag = nil
        }

        // Close any existing zap subscriptions before opening a new one
        closeAllZapSubscriptions()

        // Use a unique subscription ID per stream to avoid conflicts
        let subscriptionId = "zaps-\(streamEventId.prefix(8))"

        // Make sure this ID isn't already in use
        if subscriptionIds.contains(subscriptionId) {
            print("⚠️ Subscription \(subscriptionId) already exists, not creating duplicate")
            return
        }

        subscriptionIds.insert(subscriptionId)

        print("💬 Requesting zap receipts (paid comments) for stream:")
        print("   Event ID: \(streamEventId)")
        print("   Pubkey: \(pubkey ?? "nil")")
        print("   D-tag: \(dTag ?? "nil")")

        // Request kind 9735 (zap receipts) - these contain paid zaps with comments
        // The receipts include a "p" tag pointing to the recipient (stream creator)
        var filter: [String: Any] = [
            "kinds": [9735],
            "limit": 50
        ]

        // Filter by the "p" tag (recipient pubkey - the stream creator)
        if let pubkey = pubkey {
            filter["#p"] = [pubkey.lowercased()]
            print("   Filtering by P-tag (recipient): \(pubkey.lowercased())")
        } else {
            print("   ⚠️ Missing pubkey, cannot filter zap receipts properly")
            // Without pubkey, we can't properly filter zaps
            print("   ❌ Skipping request - need pubkey for zap receipts")
            return
        }

        let zapReq: [Any] = ["REQ", subscriptionId, filter]

        print("   Zap receipt filter:")
        print("     kinds: [9735]")
        if let pTag = filter["#p"] as? [String] {
            print("     #p: \(pTag)")
        }
        print("     limit: 50")

        // Send request via NostrClient
        do {
            try nostrClient.sendRawRequest(zapReq)
            print("   ✓ Zap receipt request sent to relays")
        } catch {
            print("   ❌ Failed to fetch zap receipts for stream: \(error)")
        }
    }

    /// Handle a received chat comment or zap
    private func handleZapReceived(_ zapComment: ZapComment) {
        print("💬 Received comment:")
        print("   ID: \(zapComment.id.prefix(8))...")
        if zapComment.amount > 0 {
            print("   Amount: \(zapComment.amountInSats) sats (zap)")
        }
        print("   Sender: \(zapComment.senderName ?? "Anonymous")")
        print("   Message: \(zapComment.comment.isEmpty ? "(empty)" : zapComment.comment)")
        print("   Stream ID: \(zapComment.streamEventId ?? "nil")")

        // Validate we have a stream identifier
        guard let streamIdentifier = zapComment.streamEventId else {
            print("   ⚠️ Skipping comment - no stream identifier")
            return
        }

        // Store comments using the a-tag as the key
        // Use currentStreamATag if we have it, otherwise use the identifier from the comment
        let storageKey = currentStreamATag ?? streamIdentifier
        var comments = zapComments[storageKey] ?? []
        print("   Current comments for this stream: \(comments.count)")

        // Add new comment if not already present
        if !comments.contains(where: { $0.id == zapComment.id }) {
            comments.append(zapComment)
            print("   ✓ Added comment (total: \(comments.count))")

            // Sort by timestamp (newest first) and keep only the latest 50
            comments.sort { $0.timestamp > $1.timestamp }
            if comments.count > 50 {
                comments = Array(comments.prefix(50))
                print("   Trimmed to 50 comments")
            }

            zapComments[storageKey] = comments

            // Also store under the comment's identifier if different
            if storageKey != streamIdentifier {
                zapComments[streamIdentifier] = comments
                print("   ✓ Also stored under comment's stream ID")
            }
        } else {
            print("   ⚠️ Comment already exists, skipping")
        }
    }

    /// Get the latest chat comments for a stream
    /// - Parameter streamEventId: The event ID or a-tag of the stream
    /// - Returns: Array of up to 50 most recent comments
    func getZapsForStream(_ streamEventId: String) -> [ZapComment] {
        // Try with current a-tag first, then fall back to the provided ID
        if let aTag = currentStreamATag {
            return zapComments[aTag] ?? zapComments[streamEventId] ?? []
        }
        return zapComments[streamEventId] ?? []
    }

    /// Clear zap comments for a specific stream
    func clearZapsForStream(_ streamEventId: String) {
        zapComments.removeValue(forKey: streamEventId)

        // Unsubscribe from this stream's zaps
        let subscriptionId = "zaps-\(streamEventId.prefix(8))"
        if subscriptionIds.contains(subscriptionId) {
            subscriptionIds.remove(subscriptionId)
            // Send CLOSE message to relays
            let closeReq: [Any] = ["CLOSE", subscriptionId]
            do {
                try nostrClient.sendRawRequest(closeReq)
                print("📪 Closed zap subscription: \(subscriptionId)")
            } catch {
                print("❌ Failed to close zap subscription: \(error)")
            }
        }
    }

    /// Close all active zap subscriptions
    private func closeAllZapSubscriptions() {
        guard !subscriptionIds.isEmpty else {
            print("📪 No existing zap subscriptions to close")
            return
        }

        print("📪 Closing \(subscriptionIds.count) existing zap subscription(s)")

        for subscriptionId in subscriptionIds {
            let closeReq: [Any] = ["CLOSE", subscriptionId]
            do {
                try nostrClient.sendRawRequest(closeReq)
                print("   ✓ Sent CLOSE for: \(subscriptionId)")
            } catch {
                print("   ❌ Failed to close \(subscriptionId): \(error)")
            }
        }

        subscriptionIds.removeAll()
        print("   ✓ Cleared all subscription IDs from tracking")
    }
}
