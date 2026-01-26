//
//  ChatConnectionManager.swift
//  nostrTV
//
//  Created by Claude Code
//  Implements Primal-style singleton pattern for reliable chat subscriptions
//

import Foundation
import Combine
import NostrSDK

/// Singleton manager for all chat subscriptions across the app.
/// Solves the callback overwriting problem by routing messages to per-subscription handlers.
///
/// **Architecture (based on Primal iOS analysis):**
/// - Single instance manages all chat subscriptions
/// - Per-subscription handlers stored by aTag (not global callback)
/// - RAII-style cleanup via ChatSubscription deinit
/// - Connection state monitoring with heartbeat
/// - Exponential backoff reconnection
///
/// **Usage:**
/// ```swift
/// let subscription = ChatConnectionManager.shared.subscribe(
///     streamPubkey: pubkey,
///     streamDTag: dTag
/// ) { message in
///     // Handle message
/// }
/// // subscription auto-cleans when deallocated
/// ```
@MainActor
final class ChatConnectionManager: ObservableObject {

    // MARK: - Singleton

    static let shared = ChatConnectionManager()

    // MARK: - Published State

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var activeSubscriptionCount: Int = 0

    // MARK: - Private Properties

    /// Per-subscription message handlers, keyed by normalized aTag
    private var messageHandlers: [String: (ZapComment) -> Void] = [:]

    /// Active Nostr subscription IDs, keyed by normalized aTag
    private var subscriptionIDs: [String: String] = [:]

    /// Reference to the SDK client
    private var nostrClient: NostrSDKClient?

    /// Connection monitoring
    private var lastMessageTime: Date = Date()
    private var heartbeatTimer: Timer?
    private var reconnectDelay: TimeInterval = 1
    private let maxReconnectDelay: TimeInterval = 30
    private let heartbeatInterval: TimeInterval = 5
    private let connectionTimeout: TimeInterval = 15

    /// Message buffer for EOSE handling (future enhancement)
    private var messageBuffers: [String: [ZapComment]] = [:]

    // MARK: - Initialization

    private init() {
        print("📡 ChatConnectionManager: Initializing singleton")
    }

    /// Configure with NostrSDKClient - call this once from app initialization
    func configure(with client: NostrSDKClient) {
        guard nostrClient == nil else {
            print("📡 ChatConnectionManager: Already configured, skipping")
            return
        }

        print("📡 ChatConnectionManager: Configuring with NostrSDKClient")
        self.nostrClient = client

        // Set up single callback that routes to appropriate handlers
        client.onChatReceived = { [weak self] comment in
            Task { @MainActor in
                self?.routeMessage(comment)
            }
        }

        // Start connection monitoring
        startHeartbeat()

        print("📡 ChatConnectionManager: Configuration complete")
    }

    // MARK: - Subscription Management

    /// Subscribe to chat messages for a specific stream
    /// - Parameters:
    ///   - streamPubkey: The stream's event author pubkey (for aTag construction)
    ///   - streamDTag: The stream's d-tag identifier
    ///   - handler: Callback for received messages
    /// - Returns: A ChatSubscription that auto-cleans on deallocation
    func subscribe(
        streamPubkey: String,
        streamDTag: String,
        handler: @escaping (ZapComment) -> Void
    ) -> ChatSubscription {
        let aTag = buildATag(pubkey: streamPubkey, dTag: streamDTag)

        print("📡 ChatConnectionManager: Subscribing to \(streamDTag)")

        // Store handler
        messageHandlers[aTag] = handler

        // Close existing subscription if any (prevents duplicates)
        if let existingSubId = subscriptionIDs[aTag] {
            print("📡 ChatConnectionManager: Closing existing subscription for resubscribe")
            nostrClient?.closeSubscription(existingSubId)
            subscriptionIDs.removeValue(forKey: aTag)
        }

        // Create new Nostr subscription
        createNostrSubscription(for: aTag, dTag: streamDTag)

        // Update count
        activeSubscriptionCount = messageHandlers.count

        // Return RAII-style subscription object
        return ChatSubscription(aTag: aTag, manager: self)
    }

    /// Internal: Unsubscribe when ChatSubscription is deallocated
    func unsubscribe(aTag: String) {
        print("📡 ChatConnectionManager: Unsubscribing from \(aTag.suffix(20))")

        // Remove handler
        messageHandlers.removeValue(forKey: aTag)

        // Close Nostr subscription
        if let subId = subscriptionIDs.removeValue(forKey: aTag) {
            nostrClient?.closeSubscription(subId)
        }

        // Clear any buffered messages
        messageBuffers.removeValue(forKey: aTag)

        // Update count
        activeSubscriptionCount = messageHandlers.count
    }

    // MARK: - Message Routing

    /// Route incoming message to appropriate handler based on aTag
    private func routeMessage(_ comment: ZapComment) {
        // Update connection state
        lastMessageTime = Date()
        if !isConnected {
            isConnected = true
            reconnectDelay = 1  // Reset backoff on successful message
        }

        // Get the stream identifier from the message
        guard let rawStreamId = comment.streamEventId else {
            print("📡 ChatConnectionManager: Message has no streamEventId, dropping")
            return
        }

        // Normalize the aTag for consistent lookup
        let normalizedATag = normalizeATag(rawStreamId)

        // Find and call the appropriate handler
        if let handler = messageHandlers[normalizedATag] {
            print("📡 ChatConnectionManager: Routing message to handler for \(normalizedATag.suffix(20))")
            handler(comment)
        } else {
            print("📡 ChatConnectionManager: No handler for \(normalizedATag.suffix(20)), \(messageHandlers.count) handlers active")
        }
    }

    // MARK: - Connection Management

    /// Start heartbeat monitoring for connection health
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkConnectionHealth()
            }
        }
    }

    /// Check if connection is still healthy
    private func checkConnectionHealth() {
        let silenceDuration = Date().timeIntervalSince(lastMessageTime)

        // Only consider unhealthy if we have active subscriptions and haven't received messages
        if silenceDuration > connectionTimeout && activeSubscriptionCount > 0 {
            if isConnected {
                print("📡 ChatConnectionManager: Connection appears dead (no messages for \(Int(silenceDuration))s)")
                isConnected = false
                attemptReconnect()
            }
        }
    }

    /// Attempt to reconnect with exponential backoff
    private func attemptReconnect() {
        print("📡 ChatConnectionManager: Attempting reconnect (delay: \(reconnectDelay)s)")

        // Reconnect the client
        nostrClient?.connect()

        // Resubscribe to all active streams
        for (aTag, _) in messageHandlers {
            // Extract dTag from aTag (format: "30311:pubkey:dTag")
            let parts = aTag.split(separator: ":")
            if parts.count >= 3 {
                let dTag = String(parts[2])
                createNostrSubscription(for: aTag, dTag: dTag)
            }
        }

        // Schedule next attempt with backoff
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self = self, !self.isConnected else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
            self.attemptReconnect()
        }
    }

    // MARK: - Helper Methods

    /// Build normalized aTag from components
    private func buildATag(pubkey: String, dTag: String) -> String {
        return "30311:\(pubkey.lowercased()):\(dTag)"
    }

    /// Normalize aTag for consistent lookup (lowercase pubkey)
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

    /// Create Nostr subscription for a stream
    private func createNostrSubscription(for aTag: String, dTag: String) {
        guard let client = nostrClient else {
            print("📡 ChatConnectionManager: No client configured!")
            return
        }

        // Create filter for kind 1311 (live chat) events
        guard let filter = Filter(
            kinds: [1311],
            tags: ["a": [aTag]],
            limit: 50  // Get last 50 messages
        ) else {
            print("📡 ChatConnectionManager: Failed to create filter")
            return
        }

        // Ensure connected
        client.connect()

        // Subscribe
        let subscriptionId = client.subscribe(
            with: filter,
            purpose: "chat-\(dTag.prefix(8))"
        )

        subscriptionIDs[aTag] = subscriptionId
        print("📡 ChatConnectionManager: Created subscription \(subscriptionId.prefix(8)) for \(dTag)")
    }
}

// MARK: - ChatSubscription (RAII-style cleanup)

/// A subscription handle that automatically unsubscribes when deallocated.
/// This ensures cleanup happens even if the view forgets to call unsubscribe.
///
/// **Important:** For reliable cleanup, call `cancel()` explicitly before deallocation.
/// The deinit serves as a fallback but may not always execute in time.
final class ChatSubscription {
    private let aTag: String
    private weak var manager: ChatConnectionManager?
    private var isCancelled = false

    init(aTag: String, manager: ChatConnectionManager) {
        self.aTag = aTag
        self.manager = manager
        print("📡 ChatSubscription: Created for \(aTag.suffix(20))")
    }

    /// Explicitly cancel the subscription. Call this from stopListening() for reliable cleanup.
    func cancel() {
        guard !isCancelled else {
            print("📡 ChatSubscription: Already cancelled \(aTag.suffix(20))")
            return
        }
        isCancelled = true
        print("📡 ChatSubscription: Cancelling \(aTag.suffix(20))")

        // Use DispatchQueue instead of Task for more reliable execution
        // Capture values before async dispatch
        let aTag = self.aTag
        let manager = self.manager
        DispatchQueue.main.async {
            manager?.unsubscribe(aTag: aTag)
        }
    }

    deinit {
        print("📡 ChatSubscription: Deallocating \(aTag.suffix(20)), cancelled=\(isCancelled)")
        // Fallback cleanup if cancel() wasn't called
        if !isCancelled {
            let aTag = self.aTag
            let manager = self.manager
            DispatchQueue.main.async {
                manager?.unsubscribe(aTag: aTag)
            }
        }
    }

    /// The stream aTag this subscription is for
    var streamATag: String { aTag }
}
