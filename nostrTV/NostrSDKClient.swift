//
//  NostrSDKClient.swift
//  nostrTV
//
//  Created by Claude Code on 1/7/26.
//  Part of NostrSDK integration refactoring
//

import Foundation
import Combine
import NostrSDK

/// A wrapper around NostrSDK's RelayPool that provides the same interface as the legacy NostrClient.
/// This allows gradual migration from custom WebSocket implementation to the official SDK.
///
/// **Architecture:**
/// - Uses `RelayPool` for multi-relay management
/// - Subscribes to events via Combine publishers
/// - Maintains backward compatibility with existing callbacks
/// - Implements profile caching (SDK doesn't provide this)
///
/// **Migration Status:** Phase 2 - Used by ChatManager
class NostrSDKClient {

    // MARK: - Singleton for Phase 2

    /// Shared instance for chat functionality (Phase 2 temporary solution)
    /// Phase 3 will pass SDK client from ContentView properly
    static let sharedForChat: NostrSDKClient = {
        let client = try! NostrSDKClient()
        client.connect()
        return client
    }()

    // MARK: - Properties

    /// The relay pool managing all relay connections
    private let relayPool: RelayPool

    /// Active subscription IDs mapped to their purpose
    private var activeSubscriptions: [String: String] = [:] // subscriptionId -> purpose

    /// Lock for thread-safe access to activeSubscriptions
    private let subscriptionsLock = NSLock()

    /// Combine cancellables storage
    private var cancellables = Set<AnyCancellable>()

    /// Profile cache with LRU eviction
    private var profileCache: [String: ProfileCacheEntry] = [:] // pubkey -> ProfileCacheEntry
    private let profileQueue = DispatchQueue(label: "com.nostrtv.sdk.profiles", attributes: .concurrent)
    private let maxProfileCacheSize = 500
    private let profileCacheTTL: TimeInterval = 24 * 60 * 60 // 24 hours

    /// Pending profile requests (deduplication)
    private var pendingProfileRequests: Set<String> = []
    private let pendingRequestsQueue = DispatchQueue(label: "com.nostrtv.sdk.pendingRequests")

    /// Rate limiter for relay requests
    private let rateLimiter = RelayRateLimiter()

    /// Batch size for profile requests
    private let profileBatchSize = 30

    // MARK: - Connection State

    /// Last time a message was received from any relay
    private var _lastMessageTime: Date = Date()
    private let lastMessageTimeLock = NSLock()

    /// Thread-safe accessor for lastMessageTime
    private var lastMessageTime: Date {
        get {
            lastMessageTimeLock.lock()
            defer { lastMessageTimeLock.unlock() }
            return _lastMessageTime
        }
        set {
            lastMessageTimeLock.lock()
            defer { lastMessageTimeLock.unlock() }
            _lastMessageTime = newValue
        }
    }

    /// Heartbeat timer for connection monitoring
    private var heartbeatTimer: Timer?

    /// Current reconnection delay (exponential backoff)
    private var _reconnectDelay: TimeInterval = 1
    private let reconnectDelayLock = NSLock()

    /// Thread-safe accessor for reconnectDelay
    private var reconnectDelay: TimeInterval {
        get {
            reconnectDelayLock.lock()
            defer { reconnectDelayLock.unlock() }
            return _reconnectDelay
        }
        set {
            reconnectDelayLock.lock()
            defer { reconnectDelayLock.unlock() }
            _reconnectDelay = newValue
        }
    }

    /// Maximum reconnection delay
    private let maxReconnectDelay: TimeInterval = 30

    /// Whether we're currently attempting to reconnect
    private var isReconnecting: Bool = false

    /// Silence threshold before considering connection dead
    private let connectionSilenceThreshold: TimeInterval = 60

    // MARK: - Callbacks (matching NostrClient interface)

    /// Called when a live stream event (kind 30311) is received
    var onStreamReceived: ((Stream) -> Void)?

    /// Called when a profile metadata event (kind 0) is received
    private var profileReceivedCallbacks: [((Profile) -> Void)] = []

    /// Called when a follow list event (kind 3) is received
    var onFollowListReceived: (([String]) -> Void)?

    /// Called when a user relay list (kind 10002) is received
    var onUserRelaysReceived: (([String]) -> Void)?

    /// Called when a zap receipt (kind 9735) is received
    var onZapReceived: ((ZapComment) -> Void)?

    /// Called when a live chat message (kind 1311) is received
    var onChatReceived: ((ZapComment) -> Void)?

    /// Called when a bunker message (kind 24133) is received
    var onBunkerMessageReceived: ((NostrEvent) -> Void)?

    // MARK: - Initialization

    /// Initialize with relay URLs
    /// - Parameter relayURLs: Array of WebSocket relay URLs (e.g., ["wss://relay.damus.io"])
    init(relayURLs: [String] = []) throws {
        print("🔧 NostrSDKClient: Initializing with \(relayURLs.count) relay URLs")
        // Convert strings to URLs
        let urls = relayURLs.compactMap { URL(string: $0) }
        print("🔧 NostrSDKClient: Converted to \(urls.count) URL objects")

        // Create relay pool
        print("🔧 NostrSDKClient: Creating RelayPool...")
        self.relayPool = try RelayPool(relayURLs: Set(urls))
        print("✅ NostrSDKClient: RelayPool created successfully")

        // Set up event stream subscription
        print("🔧 NostrSDKClient: Setting up event stream...")
        setupEventStream()
        print("✅ NostrSDKClient: Event stream setup complete")
    }

    /// Convenience initializer with default relays
    convenience init() throws {
        print("🚀 NostrSDKClient: Using default relay configuration")
        let defaultRelays = [
            "wss://relay.snort.social",
            "wss://relay.tunestr.io",
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://purplepag.es"
        ]
        print("🔧 NostrSDKClient: Default relays: \(defaultRelays.joined(separator: ", "))")
        try self.init(relayURLs: defaultRelays)
    }

    // MARK: - Connection Management

    /// Connect to all relays in the pool
    func connect() {
        print("🔌 NostrSDKClient: Connecting to relays...")
        relayPool.connect()
        startHeartbeat()
        reconnectDelay = 1  // Reset backoff on successful connect
        lastMessageTime = Date()
    }

    /// Disconnect from all relays
    func disconnect() {
        stopHeartbeat()
        relayPool.disconnect()
        cancellables.removeAll()
        subscriptionsLock.lock()
        activeSubscriptions.removeAll()
        subscriptionsLock.unlock()
    }

    // MARK: - Heartbeat Monitoring

    /// Start heartbeat timer to monitor connection health
    private func startHeartbeat() {
        // Ensure we're on the main thread for timer scheduling
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.stopHeartbeat()  // Ensure no duplicate timers

            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
                self?.checkConnectionHealth()
            }
            self.heartbeatTimer?.tolerance = 2.0  // Allow some tolerance for battery efficiency
        }
    }

    /// Stop heartbeat timer
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Check connection health and reconnect if needed
    private func checkConnectionHealth() {
        let silenceDuration = Date().timeIntervalSince(lastMessageTime)

        if silenceDuration > connectionSilenceThreshold {
            print("⚠️ NostrSDKClient: Connection appears dead (silence: \(Int(silenceDuration))s)")
            attemptReconnection()
        }
    }

    /// Attempt to reconnect with exponential backoff
    private func attemptReconnection() {
        guard !isReconnecting else { return }
        isReconnecting = true

        print("🔄 NostrSDKClient: Attempting reconnection (delay: \(reconnectDelay)s)...")

        // Disconnect cleanly first
        relayPool.disconnect()

        // Wait for backoff delay then reconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self = self else { return }

            self.relayPool.connect()
            self.lastMessageTime = Date()

            // Resubscribe to all active subscriptions
            self.resubscribeAll()

            // Increase backoff for next attempt (capped)
            self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
            self.isReconnecting = false

            print("✅ NostrSDKClient: Reconnection attempt complete")
        }
    }

    /// Resubscribe to all previously active subscriptions
    private func resubscribeAll() {
        // Store current subscriptions before clearing (thread-safe)
        subscriptionsLock.lock()
        let subscriptionsToRestore = activeSubscriptions
        activeSubscriptions.removeAll()
        subscriptionsLock.unlock()

        // Recreate subscriptions based on purpose
        for (_, purpose) in subscriptionsToRestore {
            print("🔄 NostrSDKClient: Resubscribing: \(purpose)")

            if purpose == "streams" {
                subscribeToStreams(limit: 50)
            } else if purpose == "streams-filtered" {
                // Will need to be re-triggered by StreamViewModel
                print("   ⚠️ Filtered streams subscription needs external re-trigger")
            } else if purpose.hasPrefix("chat-zaps-") {
                let aTag = String(purpose.dropFirst("chat-zaps-".count))
                subscribeToChatAndZaps(aTag: aTag)
            } else if purpose.hasPrefix("follow-list-") {
                let pubkeyPrefix = String(purpose.dropFirst("follow-list-".count))
                print("   ⚠️ Follow list subscription \(pubkeyPrefix) needs external re-trigger")
            }
            // Other subscriptions may need external re-triggering
        }
    }

    // MARK: - Event Stream Setup

    /// Set up Combine publisher to route all relay events to appropriate handlers
    private func setupEventStream() {
        relayPool.events
            .sink { [weak self] relayEvent in
                self?.handleRelayEvent(relayEvent)
            }
            .store(in: &cancellables)
    }

    /// Route incoming relay events to appropriate handlers based on event kind
    private func handleRelayEvent(_ relayEvent: RelayEvent) {
        let event = relayEvent.event

        // Update last message time for connection health monitoring
        lastMessageTime = Date()

        // Reset reconnect delay on successful message (connection is healthy)
        if reconnectDelay > 1 {
            reconnectDelay = 1
        }

        // Validate event before processing (without full signature verification for performance)
        // Signature verification is expensive; relays typically verify signatures
        // Enable full verification for high-security events if needed
        do {
            try NostrEventValidator.validateWithoutSignature(event)
        } catch {
            print("⚠️ NostrSDKClient: Event validation failed: \(error.localizedDescription)")
            return  // Skip invalid events
        }

        // Route by event kind
        switch event.kind.rawValue {
        case 0:
            handleMetadataEvent(event)
        case 3:
            handleFollowListEvent(event)
        case 1311:
            handleLiveChatEvent(event)
        case 9735:
            handleZapReceiptEvent(event)
        case 10002:
            handleRelayListEvent(event)
        case 24133:
            handleBunkerMessageEvent(event)
        case 30311:
            handleLiveStreamEvent(event)
        default:
            break
        }
    }

    // MARK: - Subscription Management

    /// Subscribe to events matching a filter
    /// - Parameter filter: NostrSDK Filter object
    /// - Returns: Subscription ID for later reference
    @discardableResult
    func subscribe(with filter: Filter, purpose: String = "custom") -> String {
        let subscriptionId = relayPool.subscribe(with: filter)
        subscriptionsLock.lock()
        activeSubscriptions[subscriptionId] = purpose
        subscriptionsLock.unlock()
        return subscriptionId
    }

    /// Close a subscription by ID
    /// - Parameter subscriptionId: The subscription ID to close
    func closeSubscription(_ subscriptionId: String) {
        relayPool.closeSubscription(with: subscriptionId)
        subscriptionsLock.lock()
        activeSubscriptions.removeValue(forKey: subscriptionId)
        subscriptionsLock.unlock()
    }

    /// Request live streams (kind 30311)
    func requestLiveStreams(limit: Int = 50) {
        print("🔧 NostrSDKClient: Requesting live streams (limit: \(limit))")
        guard let filter = Filter(kinds: [30311], limit: limit) else {
            print("❌ NostrSDKClient: Failed to create filter for live streams")
            return
        }
        let subId = subscribe(with: filter, purpose: "live-streams")
        print("✅ NostrSDKClient: Subscribed to live streams with ID: \(subId)")
    }

    /// Request follow list for a specific user (kind 3)
    /// - Parameter pubkey: The user's public key
    func requestFollowList(for pubkey: String) {
        guard let filter = Filter(authors: [pubkey], kinds: [3], limit: 1) else {
            return
        }
        subscribe(with: filter, purpose: "follow-list-\(pubkey.prefix(8))")
    }

    /// Subscribe to follow list for a specific user (kind 3), returns subscription ID
    /// - Parameter pubkey: The user's public key
    /// - Returns: Subscription ID for later closing, or nil if filter creation failed
    func subscribeToFollowList(for pubkey: String) -> String? {
        guard let filter = Filter(authors: [pubkey], kinds: [3], limit: 1) else {
            print("❌ NostrSDKClient: Failed to create follow list filter")
            return nil
        }
        return subscribe(with: filter, purpose: "follow-list-\(pubkey.prefix(8))")
    }

    /// Subscribe to profiles (kind 0) from specific authors
    /// - Parameter authors: Array of pubkeys to get profiles from
    /// - Returns: Subscription ID for later closing, or nil if filter creation failed
    func subscribeToProfiles(authors: [String]) -> String? {
        guard !authors.isEmpty else {
            print("⚠️ NostrSDKClient: Cannot subscribe with empty author list")
            return nil
        }
        guard let filter = Filter(authors: authors, kinds: [0], limit: 30) else {
            print("❌ NostrSDKClient: Failed to create profiles filter")
            return nil
        }
        let subId = subscribe(with: filter, purpose: "profiles")
        print("✅ NostrSDKClient: Subscribed to profiles for \(authors.count) authors (limit: 30): \(subId.prefix(8))...")
        return subId
    }

    /// Subscribe to live streams (kind 30311)
    /// - Parameter limit: Maximum number of events to fetch
    /// - Returns: Subscription ID for later closing, or nil if filter creation failed
    func subscribeToStreams(limit: Int = 50) -> String? {
        guard let filter = Filter(kinds: [30311], limit: limit) else {
            print("❌ NostrSDKClient: Failed to create streams filter")
            return nil
        }
        let subId = subscribe(with: filter, purpose: "streams")
        print("✅ NostrSDKClient: Subscribed to streams (limit: \(limit)): \(subId.prefix(8))...")
        return subId
    }

    /// Subscribe to live streams (kind 30311) filtered by specific authors
    /// This is more efficient than client-side filtering as it reduces bandwidth
    /// - Parameters:
    ///   - authors: Array of pubkeys to filter by (only streams from these authors)
    ///   - limit: Maximum number of events to fetch
    /// - Returns: Subscription ID for later closing, or nil if filter creation failed
    func subscribeToStreams(authors: [String], limit: Int = 50) -> String? {
        guard !authors.isEmpty else {
            print("⚠️ NostrSDKClient: Cannot subscribe with empty author list, falling back to unfiltered")
            return subscribeToStreams(limit: limit)
        }
        guard let filter = Filter(authors: authors, kinds: [30311], limit: limit) else {
            print("❌ NostrSDKClient: Failed to create author-filtered streams filter")
            return nil
        }
        let subId = subscribe(with: filter, purpose: "streams-filtered")
        print("✅ NostrSDKClient: Subscribed to streams from \(authors.count) authors (limit: \(limit)): \(subId.prefix(8))...")
        return subId
    }

    /// Subscribe to chat (kind 1311) and zaps (kind 9735) for a specific stream by a-tag
    /// - Parameter aTag: The stream's a-tag (format: "30311:<pubkey>:<d-tag>")
    /// - Returns: Subscription ID for later closing, or nil if filter creation failed
    func subscribeToChatAndZaps(aTag: String) -> String? {
        guard let filter = Filter(kinds: [1311, 9735], tags: ["a": [aTag]], limit: 100) else {
            print("❌ NostrSDKClient: Failed to create chat+zaps filter")
            return nil
        }
        let subId = subscribe(with: filter, purpose: "chat-zaps-\(aTag.suffix(16))")
        print("✅ NostrSDKClient: Subscribed to chat+zaps for \(aTag.suffix(20))...: \(subId.prefix(8))...")
        return subId
    }

    /// Subscribe to user profile (kind 0) and follow list (kind 3)
    /// - Parameter pubkey: The user's public key
    /// - Returns: Subscription ID for later closing, or nil if filter creation failed
    func subscribeToUserData(pubkey: String) -> String? {
        guard let filter = Filter(authors: [pubkey], kinds: [0, 3], limit: 2) else {
            print("❌ NostrSDKClient: Failed to create user data filter")
            return nil
        }
        return subscribe(with: filter, purpose: "user-data-\(pubkey.prefix(8))")
    }

    /// Convenience method: Connect to relays and fetch user profile + follow list
    /// - Parameter pubkey: The user's public key
    func connectAndFetchUserData(pubkey: String) {
        print("🔧 NostrSDKClient: Connecting and fetching user data for \(pubkey.prefix(16))...")
        connect()

        // Wait for connections to establish
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.requestProfile(for: pubkey)
            self.requestFollowList(for: pubkey)
        }
    }

    // MARK: - Profile Management

    /// Add a callback for profile received events (supports multiple observers)
    func addProfileReceivedCallback(_ callback: @escaping (Profile) -> Void) {
        profileReceivedCallbacks.append(callback)
    }

    /// Get cached profile for a pubkey
    /// - Parameter pubkey: The public key (hex)
    /// - Returns: Cached profile if available and not expired
    func getProfile(for pubkey: String) -> Profile? {
        guard !pubkey.isEmpty else { return nil }

        // Thread-safe read
        let result = profileQueue.sync { () -> (profile: Profile?, shouldUpdate: Bool, shouldRemove: Bool) in
            guard let entry = profileCache[pubkey] else {
                return (nil, false, false)
            }

            // Check expiration
            let now = Date()
            if now.timeIntervalSince(entry.timestamp) > profileCacheTTL {
                return (nil, false, true) // Expired
            }

            return (entry.profile, true, false) // Valid
        }

        // Update access time or remove expired entry (outside sync block)
        if result.shouldUpdate {
            profileQueue.async(flags: .barrier) { [weak self] in
                self?.profileCache[pubkey]?.lastAccessed = Date()
            }
        } else if result.shouldRemove {
            profileQueue.async(flags: .barrier) { [weak self] in
                self?.profileCache.removeValue(forKey: pubkey)
            }
        }

        return result.profile
    }

    /// Manually cache a profile
    func cacheProfile(_ profile: Profile, for pubkey: String) {
        profileQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            let now = Date()
            let entry = ProfileCacheEntry(profile: profile, timestamp: now, lastAccessed: now)

            // Evict if needed
            self.evictOldProfilesIfNeeded()

            self.profileCache[pubkey] = entry
        }
    }

    /// Evict expired and least recently used profiles
    private func evictOldProfilesIfNeeded() {
        // Must be called within barrier block
        let now = Date()

        // Remove expired
        profileCache = profileCache.filter { _, entry in
            now.timeIntervalSince(entry.timestamp) <= profileCacheTTL
        }

        // Remove LRU if over limit
        if profileCache.count >= maxProfileCacheSize {
            let toRemove = Int(Double(maxProfileCacheSize) * 0.2)
            let sorted = profileCache.sorted { $0.value.lastAccessed < $1.value.lastAccessed }

            for i in 0..<min(toRemove, sorted.count) {
                profileCache.removeValue(forKey: sorted[i].key)
            }
        }
    }

    /// Request profile metadata for a pubkey
    func requestProfile(for pubkey: String) {
        // Check rate limit
        guard rateLimiter.shouldAllowRequest() else {
            // Queue for later
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.requestProfile(for: pubkey)
            }
            return
        }

        // Deduplicate requests
        var shouldRequest = false
        pendingRequestsQueue.sync {
            if !pendingProfileRequests.contains(pubkey) {
                pendingProfileRequests.insert(pubkey)
                shouldRequest = true
            }
        }

        guard shouldRequest else { return }

        // Subscribe to profile
        guard let filter = Filter(authors: [pubkey], kinds: [0], limit: 1) else {
            return
        }

        subscribe(with: filter, purpose: "profile-\(pubkey.prefix(8))")

        // Clear pending after timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.pendingRequestsQueue.async {
                self?.pendingProfileRequests.remove(pubkey)
            }
        }
    }

    /// Request profiles for multiple pubkeys in batches (more efficient)
    /// - Parameter pubkeys: Array of pubkeys to fetch profiles for
    func requestProfiles(for pubkeys: [String]) {
        // Filter out already cached and pending profiles
        var uncachedPubkeys: [String] = []
        pendingRequestsQueue.sync {
            uncachedPubkeys = pubkeys.filter { pubkey in
                !pendingProfileRequests.contains(pubkey) && getProfile(for: pubkey) == nil
            }
        }

        guard !uncachedPubkeys.isEmpty else { return }

        // Mark all as pending
        pendingRequestsQueue.async { [weak self] in
            for pubkey in uncachedPubkeys {
                self?.pendingProfileRequests.insert(pubkey)
            }
        }

        // Batch into groups
        let batches = uncachedPubkeys.chunked(into: profileBatchSize)

        for (index, batch) in batches.enumerated() {
            // Rate limit between batches
            let delay = Double(index) * 0.2  // 200ms between batches

            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }

                // Check rate limit
                guard self.rateLimiter.shouldAllowRequest() else {
                    // Retry after delay
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        self.requestProfiles(for: batch)
                    }
                    return
                }

                guard let filter = Filter(authors: batch, kinds: [0], limit: batch.count) else {
                    return
                }

                self.subscribe(with: filter, purpose: "profiles-batch-\(index)")
                print("📋 NostrSDKClient: Requested \(batch.count) profiles in batch \(index)")
            }
        }

        // Clear pending after timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.pendingRequestsQueue.async {
                for pubkey in uncachedPubkeys {
                    self?.pendingProfileRequests.remove(pubkey)
                }
            }
        }
    }

    // MARK: - Event Handlers

    /// Handle kind 0 (metadata/profile) events
    private func handleMetadataEvent(_ event: NostrSDK.NostrEvent) {
        // SDK provides MetadataEvent subclass
        guard let metadataEvent = event as? MetadataEvent else {
            return
        }

        guard let metadata = metadataEvent.userMetadata else {
            return
        }

        let pubkey = event.pubkey

        // Convert SDK UserMetadata to our Profile model
        let profile = Profile(
            pubkey: pubkey,
            name: metadata.name,
            displayName: metadata.displayName,
            about: metadata.about,
            picture: metadata.pictureURL?.absoluteString,
            nip05: metadata.nostrAddress,
            lud16: metadata.lightningAddress ?? metadata.lightningURLString
        )

        // Cache profile
        cacheProfile(profile, for: pubkey)

        // Remove from pending
        pendingRequestsQueue.async { [weak self] in
            self?.pendingProfileRequests.remove(pubkey)
        }

        // Notify callbacks
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for callback in self.profileReceivedCallbacks {
                callback(profile)
            }
        }

    }

    /// Handle kind 3 (follow list) events
    private func handleFollowListEvent(_ event: NostrSDK.NostrEvent) {
        print("📋 NostrSDKClient: Received kind 3 follow list from \(event.pubkey.prefix(16))...")

        // Extract p tags (followed pubkeys)
        let follows = event.tags
            .filter { $0.name == "p" }
            .compactMap { $0.value }

        print("📋 NostrSDKClient: Extracted \(follows.count) follows from kind 3 event")

        DispatchQueue.main.async { [weak self] in
            self?.onFollowListReceived?(follows)
        }
    }

    /// Handle kind 10002 (relay list metadata) events
    private func handleRelayListEvent(_ event: NostrSDK.NostrEvent) {
        // Extract r tags (relay URLs)
        let relays = event.tags
            .filter { $0.name == "r" }
            .compactMap { $0.value }
            .filter { $0.hasPrefix("wss://") || $0.hasPrefix("ws://") }


        DispatchQueue.main.async { [weak self] in
            self?.onUserRelaysReceived?(relays)
        }
    }

    /// Handle kind 1311 (live chat) events
    private func handleLiveChatEvent(_ event: NostrSDK.NostrEvent) {

        let chatEventId = event.id
        let senderPubkey = event.pubkey
        let createdAt = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        let content = event.content

        // Extract "a" tag (stream reference)
        let aTag = event.tags.first { $0.name == "a" }?.value

        print("📨 NostrSDKClient: Received kind 1311 chat event")
        print("   Event ID: \(chatEventId)")
        print("   Content: \(content)")
        print("   aTag from event: \(aTag ?? "nil")")


        // Get sender's profile name if cached
        let senderName = getProfile(for: senderPubkey)?.displayName ?? getProfile(for: senderPubkey)?.name

        // Create ZapComment object (reusing existing model)
        let chatComment = ZapComment(
            id: chatEventId,
            amount: 0, // No zap amount for chat
            senderPubkey: senderPubkey,
            senderName: senderName,
            comment: content,
            timestamp: createdAt,
            streamEventId: aTag,
            bolt11: nil  // No invoice for regular chat
        )


        // Notify callback
        DispatchQueue.main.async { [weak self] in
            self?.onChatReceived?(chatComment)
        }

        // Request profile if not cached
        if getProfile(for: senderPubkey) == nil {
            requestProfile(for: senderPubkey)
        }
    }

    /// Handle kind 9735 (zap receipt) events
    private func handleZapReceiptEvent(_ event: NostrSDK.NostrEvent) {

        let zapReceiptId = event.id
        let createdAt = Date(timeIntervalSince1970: TimeInterval(event.createdAt))

        // Extract bolt11 invoice
        guard let bolt11 = event.tags.first(where: { $0.name == "bolt11" })?.value else {
            return
        }

        // Extract zap request from description tag
        guard let descriptionJSON = event.tags.first(where: { $0.name == "description" })?.value,
              let descriptionData = descriptionJSON.data(using: .utf8),
              let zapRequest = try? JSONSerialization.jsonObject(with: descriptionData) as? [String: Any] else {
            return
        }

        // Extract sender pubkey from zap request
        guard let senderPubkey = zapRequest["pubkey"] as? String else {
            return
        }

        // Extract comment from zap request
        let comment = zapRequest["content"] as? String ?? ""

        // Extract stream reference from zap request tags
        let zapRequestTags = zapRequest["tags"] as? [[Any]] ?? []
        var streamEventId: String?

        // Look for "a" tag (stream coordinate) or "e" tag (event ID)
        for tag in zapRequestTags {
            if let tagName = tag.first as? String, tag.count > 1 {
                if tagName == "a", let value = tag[1] as? String {
                    streamEventId = value
                    break
                } else if tagName == "e", let value = tag[1] as? String, streamEventId == nil {
                    streamEventId = value
                }
            }
        }

        // Parse amount from bolt11
        let amount = parseAmountFromBolt11(bolt11)

        // Get sender's profile name if cached
        let senderName = getProfile(for: senderPubkey)?.displayName ?? getProfile(for: senderPubkey)?.name

        // Create ZapComment object
        let zapComment = ZapComment(
            id: zapReceiptId,
            amount: amount,
            senderPubkey: senderPubkey,
            senderName: senderName,
            comment: comment,
            timestamp: createdAt,
            streamEventId: streamEventId,
            bolt11: bolt11
        )


        // Notify callback
        DispatchQueue.main.async { [weak self] in
            self?.onZapReceived?(zapComment)
        }

        // Request profile if not cached
        if getProfile(for: senderPubkey) == nil {
            requestProfile(for: senderPubkey)
        }
    }

    /// Handle kind 24133 (bunker message) events
    private func handleBunkerMessageEvent(_ event: NostrSDK.NostrEvent) {

        // Convert SDK NostrEvent to our legacy NostrEvent struct
        // This is needed because NostrBunkerClient expects the old format
        let legacyEvent = nostrTV.NostrEvent(
            kind: event.kind.rawValue,
            tags: event.tags.map { [$0.name, $0.value] + $0.otherParameters },
            id: event.id,
            pubkey: event.pubkey,
            created_at: Int(event.createdAt),
            content: event.content,
            sig: event.signature
        )

        // Notify callback
        DispatchQueue.main.async { [weak self] in
            self?.onBunkerMessageReceived?(legacyEvent)
        }
    }

    /// Handle kind 30311 (live stream) events
    private func handleLiveStreamEvent(_ event: NostrSDK.NostrEvent) {

        // Helper to extract tag value
        func tagValue(_ name: String) -> String? {
            event.tags.first { $0.name == name }?.value
        }

        // Extract stream metadata from tags
        let title = tagValue("title")
        let summary = tagValue("summary")
        let streamURL = tagValue("streaming") ?? tagValue("streaming_url")
        let streamID = tagValue("d")
        let status = tagValue("status") ?? "unknown"
        let imageURL = tagValue("image")

        // IMPORTANT: We need BOTH pubkeys for different purposes:
        // 1. Host pubkey (p-tag): Used for profile display
        // 2. Event author pubkey (event.pubkey): Used for a-tag coordinate in chat subscriptions
        let hostPubkey = tagValue("p") ?? event.pubkey  // Prefer p-tag, fallback to event author
        let eventAuthorPubkey = event.pubkey  // Always the event signer

        // Extract viewer count
        let viewerCount: Int = {
            if let countString = tagValue("current_participants"),
               let count = Int(countString) {
                return count
            }
            return 0
        }()

        // Extract tags (hashtags and categories)
        let hashtags = event.tags.filter { $0.name == "t" }.compactMap { $0.value }
        let gTags = event.tags.filter { $0.name == "g" }.compactMap { $0.value }
        let allTags = hashtags + gTags

        // Extract created_at
        let createdAt = Date(timeIntervalSince1970: TimeInterval(event.createdAt))

        // Validate required fields
        guard let streamID = streamID else {
            return
        }

        // Build combined title
        let combinedTitle: String = {
            if let title = title, !title.isEmpty {
                if let summary = summary, !summary.isEmpty {
                    return "\(title) — \(summary)"
                } else {
                    return title
                }
            } else if let summary = summary, !summary.isEmpty {
                return summary
            } else {
                return "(No title)"
            }
        }()

        // Use placeholder URL for ended streams
        let finalStreamURL = streamURL ?? "ended://\(streamID)"

        // Create Stream object
        let stream = Stream(
            streamID: streamID,
            eventID: event.id,
            title: combinedTitle,
            streaming_url: finalStreamURL,
            imageURL: imageURL,
            pubkey: hostPubkey,
            eventAuthorPubkey: eventAuthorPubkey,
            profile: nil, // Will be fetched separately
            status: status,
            tags: allTags,
            createdAt: createdAt,
            viewerCount: viewerCount
        )

        // Notify callback
        DispatchQueue.main.async { [weak self] in
            self?.onStreamReceived?(stream)
        }

        // Request profile for host if not cached
        if getProfile(for: hostPubkey) == nil {
            requestProfile(for: hostPubkey)
        }
    }

    // MARK: - Helper Methods

    /// Parse amount from Lightning bolt11 invoice
    private func parseAmountFromBolt11(_ invoice: String) -> Int {
        var invoice = invoice.lowercased()

        // Remove prefix
        if invoice.hasPrefix("lnbc") {
            invoice = String(invoice.dropFirst(4))
        } else if invoice.hasPrefix("lntb") {
            invoice = String(invoice.dropFirst(4))
        } else {
            return 0
        }

        // Extract amount and multiplier
        var amountString = ""
        var multiplier = 1.0

        for char in invoice {
            if char.isNumber {
                amountString.append(char)
            } else if char == "m" {
                multiplier = 0.001
                break
            } else if char == "u" {
                multiplier = 0.000001
                break
            } else if char == "n" {
                multiplier = 0.000000001
                break
            } else if char == "p" {
                multiplier = 0.000000000001
                break
            } else {
                break
            }
        }

        guard let amountValue = Double(amountString) else {
            return 0
        }

        // Convert to millisats
        let btcAmount = amountValue * multiplier
        let millisats = Int(btcAmount * 100_000_000_000)

        return millisats
    }

    // MARK: - Event Publishing

    /// Publish an event to all relays
    /// - Parameter event: The NostrSDK event to publish
    func publishEvent(_ event: NostrSDK.NostrEvent) {
        relayPool.publishEvent(event)
    }

    /// Publish a legacy NostrEvent to all relays
    /// - Parameter event: The legacy NostrEvent to publish
    /// - Throws: Error if event serialization fails
    func publishLegacyEvent(_ event: NostrEvent) throws {
        let eventDict: [String: Any] = [
            "id": event.id ?? "",
            "pubkey": event.pubkey ?? "",
            "created_at": event.created_at ?? Int(Date().timeIntervalSince1970),
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content ?? "",
            "sig": event.sig ?? ""
        ]

        guard let eventJSON = try? JSONSerialization.data(withJSONObject: eventDict),
              let eventJSONString = String(data: eventJSON, encoding: .utf8) else {
            throw NostrEventError.serializationFailed
        }

        let eventMessage = "[\"EVENT\",\(eventJSONString)]"
        relayPool.send(request: eventMessage)
    }

    /// Publish a raw message to all relays (for bunker and other special cases)
    /// - Parameter message: The raw Nostr protocol message (e.g., ["EVENT", {...}])
    func publishRawMessage(_ message: String) {
        relayPool.send(request: message)
    }

    /// Send a raw request array to all relays (for REQ, CLOSE, etc.)
    /// - Parameter request: The request array (e.g., ["REQ", "sub-id", {...}])
    /// - Throws: Error if JSON serialization fails
    func sendRawRequest(_ request: [Any]) throws {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NostrEventError.serializationFailed
        }
        relayPool.send(request: jsonString)
    }

    // MARK: - Event Creation and Signing

    /// Create and sign a Nostr event locally using a keypair
    /// - Parameters:
    ///   - kind: The event kind
    ///   - content: The event content
    ///   - tags: The event tags
    ///   - keyPair: The keypair to sign with
    /// - Returns: A signed NostrEvent (legacy format for compatibility)
    func createSignedEvent(kind: Int, content: String, tags: [[String]] = [], using keyPair: NostrKeyPair) throws -> NostrEvent {
        let pubkey = keyPair.publicKeyHex
        let created_at = Int(Date().timeIntervalSince1970)

        // Create event for signing (without id and sig)
        let eventForSigning: [Any] = [
            0,
            pubkey,
            created_at,
            kind,
            tags,
            content
        ]

        // Serialize to JSON for hashing with specific options
        // NIP-01 requires compact JSON with no whitespace and specific formatting
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: eventForSigning,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NostrEventError.serializationFailed
        }

        // Hash the serialized event
        let eventHash = jsonString.data(using: .utf8)!.sha256()
        let eventId = eventHash.hexString

        // Sign the event hash
        let signature = try keyPair.sign(messageHash: eventHash)
        let signatureHex = signature.hexString

        // Create the full signed event
        var event = NostrEvent(kind: kind, tags: tags)
        event.id = eventId
        event.pubkey = pubkey
        event.created_at = created_at
        event.content = content
        event.sig = signatureHex

        print("✅ NostrSDKClient: Created and signed event (kind: \(kind), id: \(eventId.prefix(16))...)")

        return event
    }
}

// MARK: - Profile Cache Entry

/// Cache entry for profile data with timestamp tracking
private struct ProfileCacheEntry {
    let profile: Profile
    let timestamp: Date
    var lastAccessed: Date
}

// MARK: - Rate Limiter

/// Rate limiter to prevent overwhelming relays with requests
final class RelayRateLimiter {
    /// Maximum requests per second
    private let maxRequestsPerSecond: Int

    /// Request timestamps within the current window
    private var requestTimestamps: [Date] = []

    /// Lock for thread safety
    private let lock = NSLock()

    init(maxRequestsPerSecond: Int = 10) {
        self.maxRequestsPerSecond = maxRequestsPerSecond
    }

    /// Check if a new request should be allowed
    /// - Returns: True if within rate limit, false if should be throttled
    func shouldAllowRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        // Remove timestamps older than 1 second
        requestTimestamps = requestTimestamps.filter { now.timeIntervalSince($0) < 1.0 }

        // Check if we're under the limit
        if requestTimestamps.count < maxRequestsPerSecond {
            requestTimestamps.append(now)
            return true
        }

        return false
    }

    /// Reset the rate limiter (e.g., after reconnection)
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        requestTimestamps.removeAll()
    }
}

// MARK: - Array Extension

extension Array {
    /// Split array into chunks of specified size
    /// - Parameter size: Maximum size of each chunk
    /// - Returns: Array of chunks
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
