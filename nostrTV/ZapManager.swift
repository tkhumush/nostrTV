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

    /// Fetch sample kind 9734 zap request events for comparison
    func fetchSampleZapRequests(streamPubkey: String, streamEventId: String, streamDTag: String) {
        print("\n🔍 FETCHING SAMPLE KIND 9734 ZAP REQUESTS FOR THIS STREAM")
        print(String(repeating: "=", count: 60))
        print("Stream Event ID: \(streamEventId)")
        print("Stream Pubkey: \(streamPubkey)")
        print("Stream D-tag: \(streamDTag)")
        print("Stream A-tag: 30311:\(streamPubkey):\(streamDTag)")
        print(String(repeating: "=", count: 60))

        let subscriptionId = "sample-zap-requests-\(streamEventId.prefix(8))"

        // Request 5 recent kind 9734 events that reference this stream
        // Kind 9734 events should have either an "e" tag or "a" tag pointing to the stream
        var filter: [String: Any] = [
            "kinds": [9734],
            "limit": 5
        ]

        // Try filtering by the stream's recipient pubkey (p tag)
        filter["#p"] = [streamPubkey.lowercased()]

        let zapReq: [Any] = ["REQ", subscriptionId, filter]

        do {
            try nostrClient.sendRawRequest(zapReq)
            print("✓ Requested 5 sample kind 9734 events for this stream")
            print("  Filtering by p-tag (recipient): \(streamPubkey.lowercased())")
            print("  (These will be printed when received)\n")
        } catch {
            print("❌ Failed to fetch sample zap requests: \(error)")
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
        // Validate we have a stream identifier
        guard let streamIdentifier = zapComment.streamEventId else {
            return
        }

        // Store comments using the a-tag as the key
        // Use currentStreamATag if we have it, otherwise use the identifier from the comment
        let storageKey = currentStreamATag ?? streamIdentifier
        var comments = zapComments[storageKey] ?? []

        // Add new comment if not already present
        if !comments.contains(where: { $0.id == zapComment.id }) {
            comments.append(zapComment)

            // Sort by timestamp (newest first) and keep only the latest 50
            comments.sort { $0.timestamp > $1.timestamp }
            if comments.count > 50 {
                comments = Array(comments.prefix(50))
            }

            zapComments[storageKey] = comments

            // Also store under the comment's identifier if different
            if storageKey != streamIdentifier {
                zapComments[streamIdentifier] = comments
            }
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
