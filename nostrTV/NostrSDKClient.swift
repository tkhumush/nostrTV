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
    }

    /// Disconnect from all relays
    func disconnect() {
        relayPool.disconnect()
        cancellables.removeAll()
        activeSubscriptions.removeAll()
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

        // Log all events for debugging
        print("📨 NostrSDKClient: Received event kind \(event.kind.rawValue) from relay")

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
            print("🎥 NostrSDKClient: Processing live stream event")
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
        activeSubscriptions[subscriptionId] = purpose
        return subscriptionId
    }

    /// Close a subscription by ID
    /// - Parameter subscriptionId: The subscription ID to close
    func closeSubscription(_ subscriptionId: String) {
        relayPool.closeSubscription(with: subscriptionId)
        activeSubscriptions.removeValue(forKey: subscriptionId)
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

    /// Convenience method: Connect to relays and fetch user profile + follow list
    /// - Parameter pubkey: The user's public key
    func connectAndFetchUserData(pubkey: String) {
        print("🔧 NostrSDKClient: Connecting and fetching user data for \(pubkey.prefix(16))...")
        connect()

        // Wait for connections to establish
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            print("🔧 NostrSDKClient: Requesting profile and follow list...")
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
        // Extract p tags (followed pubkeys)
        let follows = event.tags
            .filter { $0.name == "p" }
            .compactMap { $0.value }


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
            streamEventId: aTag
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
            streamEventId: streamEventId
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
        print("📢 NostrSDKClient: Calling onStreamReceived for stream: \(stream.title)")
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
