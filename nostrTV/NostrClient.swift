//
//  NostrClient.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import Foundation
import CommonCrypto

struct NostrEvent: Codable {
    let kind: Int
    let tags: [[String]]

    // Full event structure for creating and signing
    var id: String?
    var pubkey: String?
    var created_at: Int?
    var content: String?
    var sig: String?

    enum CodingKeys: String, CodingKey {
        case id, pubkey, created_at, content, kind, tags, sig
    }
}

struct NostrProfile: Codable {
    let name: String?
    let displayName: String?
    let about: String?
    let picture: String?
    let nip05: String?
    let lud16: String?
}

// MARK: - Profile Cache Entry
private struct ProfileCacheEntry {
    let profile: Profile
    let timestamp: Date
    var lastAccessed: Date
}

class NostrClient {
    private var webSocketTasks: [URL: URLSessionWebSocketTask] = [:]
    private var profileCache: [String: ProfileCacheEntry] = [:] // pubkey -> ProfileCacheEntry
    private var followListEvents: [String: (timestamp: Int, follows: [String])] = [:] // pubkey -> (created_at, follows)
    private var userRelays: [String] = [] // User's relay list from NIP-65 (kind 10002) or kind 3
    private var session: URLSession!
    private let profileQueue = DispatchQueue(label: "com.nostrtv.profiles", attributes: .concurrent)
    private var pendingProfileRequests: Set<String> = [] // Track in-flight profile requests
    private let pendingRequestsQueue = DispatchQueue(label: "com.nostrtv.pendingRequests")

    // Profile cache configuration
    private let maxProfileCacheSize = 500
    private let profileCacheTTL: TimeInterval = 24 * 60 * 60 // 24 hours

    var onStreamReceived: ((Stream) -> Void)?
    private var profileReceivedCallbacks: [((Profile) -> Void)] = []
    var onFollowListReceived: (([String]) -> Void)?
    var onUserRelaysReceived: (([String]) -> Void)?
    var onZapReceived: ((ZapComment) -> Void)?
    var onChatReceived: ((ZapComment) -> Void)?  // Separate callback for chat messages (kind 1311)
    var onBunkerMessageReceived: ((NostrEvent) -> Void)?  // Callback for NIP-46 bunker messages (kind 24133)

    // Add a profile received callback (supports multiple observers)
    func addProfileReceivedCallback(_ callback: @escaping (Profile) -> Void) {
        profileReceivedCallbacks.append(callback)
    }

    func getProfile(for pubkey: String) -> Profile? {
        guard !pubkey.isEmpty else {
            return nil
        }

        // Read the profile entry
        let result = profileQueue.sync { () -> (profile: Profile?, shouldUpdate: Bool, shouldRemove: Bool) in
            guard let entry = profileCache[pubkey] else {
                return (nil, false, false)
            }

            // Check if profile has expired
            let now = Date()
            if now.timeIntervalSince(entry.timestamp) > profileCacheTTL {
                return (nil, false, true) // Profile expired, should remove
            }

            return (entry.profile, true, false) // Valid profile, should update access time
        }

        // Handle updates outside of sync block
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

    /// Manually cache a profile (useful for caching our own profile immediately after publishing)
    func cacheProfile(_ profile: Profile, for pubkey: String) {
        profileQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            let now = Date()
            let entry = ProfileCacheEntry(profile: profile, timestamp: now, lastAccessed: now)

            // Evict old entries if cache is full
            self.evictOldProfilesIfNeeded()

            self.profileCache[pubkey] = entry
        }
        print("✅ Cached profile for \(pubkey.prefix(8))... - \(profile.displayName ?? profile.name ?? "Unknown")")
    }

    /// Evict expired and least recently used profiles when cache is full
    private func evictOldProfilesIfNeeded() {
        // This should be called within a barrier block (write lock)
        let now = Date()

        // First, remove expired profiles
        profileCache = profileCache.filter { _, entry in
            now.timeIntervalSince(entry.timestamp) <= profileCacheTTL
        }

        // If still over limit, remove least recently used
        if profileCache.count >= maxProfileCacheSize {
            // Sort by last accessed time and remove oldest 20%
            let entriesToRemove = Int(Double(maxProfileCacheSize) * 0.2)
            let sortedByAccess = profileCache.sorted { $0.value.lastAccessed < $1.value.lastAccessed }

            for i in 0..<min(entriesToRemove, sortedByAccess.count) {
                profileCache.removeValue(forKey: sortedByAccess[i].key)
            }
        }
    }

    func connect() {
        session = URLSession(configuration: .default)
        let relayURLs = [
            URL(string: "wss://relay.snort.social")!,
            URL(string: "wss://relay.tunestr.io")!,
            URL(string: "wss://relay.damus.io")!,
            URL(string: "wss://relay.primal.net")!,
            URL(string: "wss://purplepag.es")!
        ]

        for url in relayURLs {
            let task = session.webSocketTask(with: url)
            webSocketTasks[url] = task
            task.resume()

            // Request live streams
            let streamReq: [Any] = [
                "REQ",
                "live-streams",
                ["kinds": [30311], "limit": 50]
            ]
            sendJSON(streamReq, on: task, relayURL: url)

            // Listen for messages
            listen(on: task, from: url)
        }
    }

    private func sendJSON(_ message: [Any], on task: URLSessionWebSocketTask, relayURL: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        task.send(.string(jsonString)) { error in
            // Error handling silently
        }
    }

    private func listen(on task: URLSessionWebSocketTask, from relayURL: URL) {
        task.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure:
                break
            case .success(let message):
                if case let .string(text) = message {
                    self.handleMessage(text)
                }
                self.listen(on: task, from: relayURL)
            }
        }
    }

    // handleReconnect removed (no longer used)

    private func extractTagValue(_ key: String, from tags: [[Any]]) -> String? {
        for tag in tags {
            guard let tagKey = tag.first as? String, tagKey == key,
                  tag.count > 1,
                  let value = tag[1] as? String else {
                continue
            }
            return value
        }
        return nil
    }

    private func extractTagValues(_ key: String, from tags: [[Any]]) -> [String] {
        var values: [String] = []
        for tag in tags {
            guard let tagKey = tag.first as? String, tagKey == key,
                  tag.count > 1,
                  let value = tag[1] as? String else {
                continue
            }
            values.append(value)
        }
        return values
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let messageType = json[0] as? String else {
            return
        }

        // Handle different message types
        switch messageType {
        case "EVENT":
            guard json.count >= 3 else {
                return
            }
            handleEvent(json)
        case "EOSE":
            // End of stored events (silent)
            break
        case "OK":
            // Handle relay response to our published events
            if json.count >= 3 {
                let eventId = json[1] as? String ?? "unknown"
                let accepted = json[2] as? Bool ?? false
                let message = json.count >= 4 ? (json[3] as? String ?? "") : ""

                if accepted {
                    print("✅ Relay accepted event: \(eventId.prefix(8))...")
                } else {
                    print("❌ Relay rejected event: \(eventId.prefix(8))...")
                    print("   Reason: \(message)")
                }
            }
            break
        case "NOTICE":
            // Relay notice
            if json.count >= 2, let notice = json[1] as? String {
                print("📢 Relay notice: \(notice)")
            }
            break
        default:
            break
        }
    }
    
    private func handleEvent(_ json: [Any]) {
        guard let eventDict = json[2] as? [String: Any],
              let kind = eventDict["kind"] as? Int else {
            return
        }

        // Print raw kind 9734 events for comparison
        if kind == 9734 {
            print("\n📋 SAMPLE KIND 9734 ZAP REQUEST EVENT:")
            print(String(repeating: "-", count: 60))
            if let jsonData = try? JSONSerialization.data(withJSONObject: eventDict, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
            print(String(repeating: "-", count: 60))
        }

        switch kind {
        case 0:
            handleProfileEvent(eventDict)
        case 3:
            handleFollowListEvent(eventDict)
        case 1311:
            handleLiveChatEvent(eventDict)
        case 9735:
            handleZapReceiptEvent(eventDict)
        case 10002:
            handleRelayListEvent(eventDict)
        case 24133:
            handleBunkerMessage(eventDict)
        case 30311:
            handleStreamEvent(eventDict)
        default:
            break
        }
    }
    
    private func handleStreamEvent(_ eventDict: [String: Any]) {
        guard let tagsAny = eventDict["tags"] as? [[Any]] else {
            return
        }

        // Extract the actual event ID (for zap references)
        let eventID = eventDict["id"] as? String

        let title = extractTagValue("title", from: tagsAny)
        let summary = extractTagValue("summary", from: tagsAny)
        let streamURL = extractTagValue("streaming", from: tagsAny) ?? extractTagValue("streaming_url", from: tagsAny)
        let streamID = extractTagValue("d", from: tagsAny)
        let status = extractTagValue("status", from: tagsAny) ?? "unknown"
        let imageURL = extractTagValue("image", from: tagsAny)

        // IMPORTANT: We need BOTH pubkeys for different purposes:
        // 1. Host pubkey (p-tag): Used for profile display
        // 2. Event author pubkey (event.pubkey): Used for a-tag coordinate in chat subscriptions
        let hostPubkey = extractTagValue("p", from: tagsAny) ?? eventDict["pubkey"] as? String
        let eventAuthorPubkey = eventDict["pubkey"] as? String

        // Extract viewer count from current_participants tag
        let viewerCount: Int = {
            if let countString = extractTagValue("current_participants", from: tagsAny),
               let count = Int(countString) {
                return count
            }
            return 0
        }()

        // Extract hashtags and other tags for categorization
        let hashtags = extractTagValues("t", from: tagsAny)
        let allTags = hashtags + extractTagValues("g", from: tagsAny) // g tags are also used for categories

        // Extract created_at timestamp
        let createdAt: Date? = {
            if let timestamp = eventDict["created_at"] as? TimeInterval {
                return Date(timeIntervalSince1970: timestamp)
            }
            return nil
        }()

        // Only require streamID for processing
        guard let streamID = streamID else {
            return
        }


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

        // Use a placeholder URL for ended streams if no URL is provided
        let finalStreamURL = streamURL ?? "ended://\(streamID)"

        // Stream received (removed verbose logging)

        // Create stream with all information
        let stream = Stream(
            streamID: streamID,
            eventID: eventID,
            title: combinedTitle,
            streaming_url: finalStreamURL,
            imageURL: imageURL,
            pubkey: hostPubkey,
            eventAuthorPubkey: eventAuthorPubkey,
            profile: nil,
            status: status,
            tags: allTags,
            createdAt: createdAt,
            viewerCount: viewerCount
        )

        DispatchQueue.main.async {
            self.onStreamReceived?(stream)
        }

        // If we have a host pubkey, request the profile if we don't have it
        if let pubkey = hostPubkey {
            let hasProfile = profileQueue.sync {
                return self.profileCache[pubkey] != nil
            }
            if !hasProfile {
                requestProfile(for: pubkey)
            }
        }
    }
    
    private func handleProfileEvent(_ eventDict: [String: Any]) {
        guard let pubkey = eventDict["pubkey"] as? String,
              let content = eventDict["content"] as? String else {
            return
        }

        // Parse the content as JSON
        guard let data = content.data(using: .utf8),
              let profileData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Create profile object
        let profile = Profile(
            pubkey: pubkey,
            name: profileData["name"] as? String,
            displayName: profileData["display_name"] as? String,
            about: profileData["about"] as? String,
            picture: profileData["picture"] as? String,
            nip05: profileData["nip05"] as? String,
            lud16: profileData["lud16"] as? String
        )

        // Store profile (thread-safe) with LRU eviction
        profileQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            let now = Date()
            let entry = ProfileCacheEntry(profile: profile, timestamp: now, lastAccessed: now)

            // Evict old entries if cache is full
            self.evictOldProfilesIfNeeded()

            self.profileCache[pubkey] = entry
        }
        // Profile updated (removed verbose logging)

        // Remove from pending requests since we got the profile
        pendingRequestsQueue.async { [weak self] in
            self?.pendingProfileRequests.remove(pubkey)
        }

        // Notify all profile callbacks
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for callback in self.profileReceivedCallbacks {
                callback(profile)
            }
        }
    }

    private func handleFollowListEvent(_ eventDict: [String: Any]) {
        guard let tagsAny = eventDict["tags"] as? [[Any]],
              let pubkey = eventDict["pubkey"] as? String,
              let createdAt = eventDict["created_at"] as? Int else {
            return
        }

        // Check if we already have a follow list for this pubkey
        if let existing = followListEvents[pubkey] {
            // Only process if this event is newer
            if createdAt <= existing.timestamp {
                // Skipping older follow list event (silent)
                return
            }
        }

        // Extract all "p" tags which represent followed pubkeys
        var follows: [String] = []
        for tag in tagsAny {
            guard let tagKey = tag.first as? String, tagKey == "p",
                  tag.count > 1,
                  let followedPubkey = tag[1] as? String else {
                continue
            }
            follows.append(followedPubkey)
        }

        // Follow list received (removed verbose logging)

        // Store the most recent follow list
        followListEvents[pubkey] = (timestamp: createdAt, follows: follows)

        // Extract relay list from content field (fallback if NIP-65 not available)
        if userRelays.isEmpty, let content = eventDict["content"] as? String, !content.isEmpty {
            extractRelaysFromKind3Content(content)
        }

        // Notify callback
        DispatchQueue.main.async {
            self.onFollowListReceived?(follows)
        }
    }

    private func extractRelaysFromKind3Content(_ content: String) {
        // Kind 3 content can contain a JSON object with relay URLs
        guard let data = content.data(using: .utf8),
              let relayDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Extract relay URLs from the dictionary keys
        var relays: [String] = []
        for (relayURL, _) in relayDict {
            // Validate that it looks like a WebSocket URL
            if relayURL.hasPrefix("wss://") || relayURL.hasPrefix("ws://") {
                relays.append(relayURL)
            }
        }

        if !relays.isEmpty {
            // Extracted relays from kind 3 content (removed verbose logging)
            userRelays = relays

            DispatchQueue.main.async {
                self.onUserRelaysReceived?(relays)
            }
        }
    }

    private func handleRelayListEvent(_ eventDict: [String: Any]) {
        guard let tagsAny = eventDict["tags"] as? [[Any]] else {
            return
        }

        // Extract all "r" tags which represent relay URLs (NIP-65)
        var relays: [String] = []
        for tag in tagsAny {
            guard let tagKey = tag.first as? String, tagKey == "r",
                  tag.count > 1,
                  let relayURL = tag[1] as? String else {
                continue
            }
            // Validate WebSocket URL
            if relayURL.hasPrefix("wss://") || relayURL.hasPrefix("ws://") {
                relays.append(relayURL)
            }
        }

        if !relays.isEmpty {
            // Relay list (NIP-65) received (removed verbose logging)
            userRelays = relays

            DispatchQueue.main.async {
                self.onUserRelaysReceived?(relays)
            }
        }
    }

    private func handleLiveChatEvent(_ eventDict: [String: Any]) {
        print("💬 Received kind 1311 (live chat) event")

        guard let tagsAny = eventDict["tags"] as? [[Any]],
              let chatEventId = eventDict["id"] as? String,
              let senderPubkey = eventDict["pubkey"] as? String,
              let createdAt = eventDict["created_at"] as? TimeInterval,
              let content = eventDict["content"] as? String else {
            print("   ❌ Missing required fields")
            return
        }

        print("   Event ID: \(chatEventId.prefix(8))...")
        print("   Sender: \(senderPubkey.prefix(8))...")
        print("   Message: \(content)")

        // Extract the "a" tag which references the stream
        // Format: ["a", "30311:<pubkey>:<d-tag>"]
        let aTag = extractTagValue("a", from: tagsAny)
        print("   A-tag: \(aTag ?? "nil")")

        // Get sender's profile name if available (thread-safe)
        let senderName = profileQueue.sync {
            return profileCache[senderPubkey]?.profile.displayName ?? profileCache[senderPubkey]?.profile.name
        }
        print("   Sender name: \(senderName ?? "not cached")")

        // Create a ZapComment object (with amount = 0 for regular chat)
        let chatComment = ZapComment(
            id: chatEventId,
            amount: 0,  // No zap amount for regular chat
            senderPubkey: senderPubkey,
            senderName: senderName,
            comment: content,
            timestamp: Date(timeIntervalSince1970: createdAt),
            streamEventId: aTag,  // Use the a-tag as the stream identifier
            bolt11: nil  // No invoice for regular chat
        )

        print("   ✓ Created chat comment object, notifying callback")

        // Notify chat callback (kind 1311 messages)
        DispatchQueue.main.async {
            self.onChatReceived?(chatComment)
        }

        // Request sender profile if we don't have it
        let hasProfile = profileQueue.sync {
            return profileCache[senderPubkey] != nil
        }
        if !hasProfile {
            requestProfile(for: senderPubkey)
        }
    }

    private func handleZapReceiptEvent(_ eventDict: [String: Any]) {
        guard let tagsAny = eventDict["tags"] as? [[Any]],
              let zapReceiptId = eventDict["id"] as? String,
              let createdAt = eventDict["created_at"] as? TimeInterval else {
            return
        }

        // Extract bolt11 invoice to get the amount
        guard let bolt11 = extractTagValue("bolt11", from: tagsAny) else {
            return
        }

        // Extract the zap request from the description tag
        guard let descriptionJSON = extractTagValue("description", from: tagsAny),
              let descriptionData = descriptionJSON.data(using: .utf8),
              let zapRequest = try? JSONSerialization.jsonObject(with: descriptionData) as? [String: Any] else {
            return
        }

        // Extract sender pubkey from the zap request
        guard let senderPubkey = zapRequest["pubkey"] as? String else {
            return
        }

        // Extract comment from zap request content
        let comment = zapRequest["content"] as? String ?? ""

        // Extract stream reference from zap request tags
        // Try "a" tag first (for stream coordinate), then fall back to "e" tag (for event ID)
        let zapRequestTags = zapRequest["tags"] as? [[Any]] ?? []
        let aTag = extractTagValue("a", from: zapRequestTags)
        let eTag = extractTagValue("e", from: zapRequestTags)
        let streamEventId = aTag ?? eTag

        // Parse amount from bolt11 invoice
        let amount = parseAmountFromBolt11(bolt11)

        // Get sender's profile name if available (thread-safe)
        let senderName = profileQueue.sync {
            return profileCache[senderPubkey]?.profile.displayName ?? profileCache[senderPubkey]?.profile.name
        }

        // Create ZapComment object
        let zapComment = ZapComment(
            id: zapReceiptId,
            amount: amount,
            senderPubkey: senderPubkey,
            senderName: senderName,
            comment: comment,
            timestamp: Date(timeIntervalSince1970: createdAt),
            streamEventId: streamEventId,
            bolt11: bolt11
        )

        // Notify callback
        DispatchQueue.main.async {
            self.onZapReceived?(zapComment)
        }

        // Request sender profile if we don't have it
        let hasProfile = profileQueue.sync {
            return profileCache[senderPubkey] != nil
        }
        if !hasProfile {
            requestProfile(for: senderPubkey)
        }
    }

    private func parseAmountFromBolt11(_ invoice: String) -> Int {
        // Lightning invoice format: lnbc<amount><multiplier>1...
        // Multipliers: m (milli) = 0.001, u (micro) = 0.000001, n (nano) = 0.000000001, p (pico) = 0.000000000001
        // Amount is in BTC, we need to return millisats

        // Remove "lnbc" prefix if present (or "lntb" for testnet)
        var invoice = invoice.lowercased()
        if invoice.hasPrefix("lnbc") {
            invoice = String(invoice.dropFirst(4))
        } else if invoice.hasPrefix("lntb") {
            invoice = String(invoice.dropFirst(4))
        } else {
            return 0
        }

        // Find the multiplier character (m, u, n, p) or digit 1 which marks the end of amount
        var amountString = ""
        var multiplier = 1.0

        for char in invoice {
            if char.isNumber {
                amountString.append(char)
            } else if char == "m" {
                multiplier = 0.001 // milli-bitcoin
                break
            } else if char == "u" {
                multiplier = 0.000001 // micro-bitcoin
                break
            } else if char == "n" {
                multiplier = 0.000000001 // nano-bitcoin
                break
            } else if char == "p" {
                multiplier = 0.000000000001 // pico-bitcoin
                break
            } else {
                // If we hit a non-numeric, non-multiplier character, stop
                break
            }
        }

        guard let amountValue = Double(amountString) else {
            return 0
        }

        // Convert to millisats
        // 1 BTC = 100,000,000 sats = 100,000,000,000 millisats
        let btcAmount = amountValue * multiplier
        let millisats = Int(btcAmount * 100_000_000_000)

        return millisats
    }

    private func handleBunkerMessage(_ eventDict: [String: Any]) {
        // Convert event dictionary to NostrEvent and pass to callback
        guard let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
              let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) else {
            print("❌ Failed to parse kind 24133 bunker message")
            return
        }

        // Dispatch to main thread for callback
        DispatchQueue.main.async { [weak self] in
            self?.onBunkerMessageReceived?(event)
        }
    }

    private func requestProfile(for pubkey: String) {
        // Check if we already have a pending request for this pubkey
        var shouldRequest = false
        pendingRequestsQueue.sync {
            if !pendingProfileRequests.contains(pubkey) {
                pendingProfileRequests.insert(pubkey)
                shouldRequest = true
            }
        }

        guard shouldRequest else {
            return // Already requesting this profile
        }

        // Send a request for this specific profile
        let profileReq: [Any] = [
            "REQ",
            "profile-\(pubkey.prefix(8))", // Unique subscription ID
            ["kinds": [0], "authors": [pubkey], "limit": 1]
        ]

        // Only send to the first connected relay to reduce bandwidth
        // Most profiles exist on all major relays, so one request is sufficient
        if let firstRelay = webSocketTasks.first {
            sendJSON(profileReq, on: firstRelay.value, relayURL: firstRelay.key)
        }

        // Remove from pending set after a timeout (30 seconds) to allow retry if needed
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.pendingRequestsQueue.async {
                self?.pendingProfileRequests.remove(pubkey)
            }
        }
    }
    
    func connectAndFetchUserData(pubkey: String) {
        session = URLSession(configuration: .default)

        // Phase 1: Connect to default relays to fetch user's relay list
        let defaultRelayURLs = [
            URL(string: "wss://relay.snort.social")!,
            URL(string: "wss://relay.tunestr.io")!,
            URL(string: "wss://relay.damus.io")!,
            URL(string: "wss://relay.primal.net")!,
            URL(string: "wss://purplepag.es")!
        ]

        for url in defaultRelayURLs {
            let task = session.webSocketTask(with: url)
            webSocketTasks[url] = task
            task.resume()

            // Request user's relay list (NIP-65, kind 10002) - highest priority
            let relayListReq: [Any] = [
                "REQ",
                "user-relays",
                ["kinds": [10002], "authors": [pubkey], "limit": 1]
            ]
            sendJSON(relayListReq, on: task, relayURL: url)

            // Request user profile (kind 0)
            let profileReq: [Any] = [
                "REQ",
                "user-profile",
                ["kinds": [0], "authors": [pubkey], "limit": 1]
            ]
            sendJSON(profileReq, on: task, relayURL: url)

            // Request follow list (kind 3) - also contains relay info in content
            // Request multiple events to ensure we get the most recent one across relays
            let followReq: [Any] = [
                "REQ",
                "user-follows",
                ["kinds": [3], "authors": [pubkey], "limit": 10]
            ]
            sendJSON(followReq, on: task, relayURL: url)

            // Listen for messages
            listen(on: task, from: url)
        }

        // Phase 2: After receiving relay list, reconnect using user's relays
        // This happens automatically via the callback when relays are received
        setupRelayListCallback(pubkey: pubkey)
    }

    private func setupRelayListCallback(pubkey: String) {
        // Set up a one-time callback to reconnect with user's relays
        var hasReconnected = false

        let originalCallback = onUserRelaysReceived
        onUserRelaysReceived = { [weak self] relays in
            guard let self = self, !hasReconnected else {
                originalCallback?(relays)
                return
            }
            hasReconnected = true

            // Call original callback first
            originalCallback?(relays)

            // Reconnecting to user's personal relays (removed verbose logging)

            // Disconnect from default relays
            self.disconnect()

            // Wait a brief moment before reconnecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.connectToUserRelays(pubkey: pubkey, relays: relays)
            }
        }
    }

    private func connectToUserRelays(pubkey: String, relays: [String]) {
        session = URLSession(configuration: .default)

        // Convert relay strings to URLs and connect
        let relayURLs = relays.compactMap { URL(string: $0) }

        guard !relayURLs.isEmpty else {
            return
        }

        for url in relayURLs {
            let task = session.webSocketTask(with: url)
            webSocketTasks[url] = task
            task.resume()

            // Request user profile (kind 0) again from user's relays
            let profileReq: [Any] = [
                "REQ",
                "user-profile-personal",
                ["kinds": [0], "authors": [pubkey], "limit": 1]
            ]
            sendJSON(profileReq, on: task, relayURL: url)

            // Request follow list (kind 3) from user's relays - most likely to have latest
            let followReq: [Any] = [
                "REQ",
                "user-follows-personal",
                ["kinds": [3], "authors": [pubkey], "limit": 10]
            ]
            sendJSON(followReq, on: task, relayURL: url)

            // Listen for messages
            listen(on: task, from: url)
        }
    }

    func disconnect() {
        for (_, task) in webSocketTasks {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTasks.removeAll()
        // Disconnected from all relays (removed verbose logging)
    }

    /// Send a raw request to all connected relays
    /// - Parameter request: Array representing the Nostr request (e.g., ["REQ", "sub-id", {...}])
    func sendRawRequest(_ request: [Any]) throws {
        // Validate that we can serialize the request
        _ = try JSONSerialization.data(withJSONObject: request)

        // Send to all connected relays
        for (url, task) in webSocketTasks {
            sendJSON(request, on: task, relayURL: url)
        }
    }

    /// Connect to a specific relay
    /// - Parameter relayURL: The relay URL to connect to (e.g., "wss://relay.nsecbunker.com")
    /// - Returns: True if connection was established or already exists, false otherwise
    @discardableResult
    func connectToRelay(_ relayURL: String) -> Bool {
        guard let url = URL(string: relayURL) else {
            print("❌ Invalid relay URL: \(relayURL)")
            return false
        }

        // Check if already connected
        if webSocketTasks[url] != nil {
            print("✅ Already connected to \(relayURL)")
            return true
        }

        // Ensure session exists
        if session == nil {
            session = URLSession(configuration: .default)
        }

        // Create and start WebSocket task
        let task = session.webSocketTask(with: url)
        webSocketTasks[url] = task
        task.resume()

        // Start listening for messages
        listen(on: task, from: url)

        print("✅ Connected to bunker relay: \(relayURL)")
        return true
    }

    /// Send a request to a specific relay
    /// - Parameters:
    ///   - request: Array representing the Nostr request (e.g., ["REQ", "sub-id", {...}])
    ///   - relayURL: The relay URL to send to (e.g., "wss://relay.nsecbunker.com")
    func sendRequest(_ request: [Any], to relayURL: String) throws {
        guard let url = URL(string: relayURL) else {
            throw NSError(domain: "NostrClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid relay URL: \(relayURL)"])
        }

        guard let task = webSocketTasks[url] else {
            throw NSError(domain: "NostrClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not connected to relay: \(relayURL)"])
        }

        // Validate that we can serialize the request
        _ = try JSONSerialization.data(withJSONObject: request)

        // Send to specific relay
        sendJSON(request, on: task, relayURL: url)
        print("📤 Sent request to \(relayURL): \(request.first ?? "unknown")")
    }

    // MARK: - Event Creation and Signing

    /// Create a Nostr event with the given parameters
    /// - Parameters:
    ///   - kind: Event kind (e.g., 1 for text note, 4 for DM, etc.)
    ///   - content: Event content
    ///   - tags: Event tags (array of string arrays)
    ///   - keyPair: Key pair to sign the event with
    /// - Returns: Signed NostrEvent ready to publish
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

        // Created and signed event (removed verbose logging)

        return event
    }

    /// Publish a signed event to all connected relays
    /// - Parameter event: The signed event to publish
    func publishEvent(_ event: NostrEvent) throws {
        guard let eventId = event.id,
              let pubkey = event.pubkey,
              let createdAt = event.created_at,
              let content = event.content,
              let sig = event.sig else {
            throw NostrEventError.incompleteEvent
        }

        // Create EVENT message format: ["EVENT", {event}]
        let eventDict: [String: Any] = [
            "id": eventId,
            "pubkey": pubkey,
            "created_at": createdAt,
            "kind": event.kind,
            "tags": event.tags,
            "content": content,
            "sig": sig
        ]

        let message: [Any] = ["EVENT", eventDict]

        // Log relay connections
        print("📡 Publishing to \(webSocketTasks.count) relay(s):")
        for (url, _) in webSocketTasks {
            print("   - \(url)")
        }

        // Send to all connected relays
        for (url, task) in webSocketTasks {
            sendJSON(message, on: task, relayURL: url)
            print("   ✓ Sent to \(url)")
        }

        if webSocketTasks.isEmpty {
            print("⚠️ WARNING: No WebSocket connections available!")
        }
    }

    /// Publish a signed event to a specific relay
    /// - Parameters:
    ///   - event: The signed event to publish
    ///   - relayURL: The relay URL to publish to
    func publishEvent(_ event: NostrEvent, to relayURL: String) throws {
        guard let eventId = event.id,
              let pubkey = event.pubkey,
              let createdAt = event.created_at,
              let content = event.content,
              let sig = event.sig else {
            throw NostrEventError.incompleteEvent
        }

        guard let url = URL(string: relayURL) else {
            throw NSError(domain: "NostrClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid relay URL: \(relayURL)"])
        }

        guard let task = webSocketTasks[url] else {
            throw NSError(domain: "NostrClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not connected to relay: \(relayURL)"])
        }

        // Create EVENT message format: ["EVENT", {event}]
        let eventDict: [String: Any] = [
            "id": eventId,
            "pubkey": pubkey,
            "created_at": createdAt,
            "kind": event.kind,
            "tags": event.tags,
            "content": content,
            "sig": sig
        ]

        let message: [Any] = ["EVENT", eventDict]

        // Send to specific relay
        sendJSON(message, on: task, relayURL: url)
        print("📤 Published event (kind \(event.kind)) to \(relayURL)")
    }

    /// Create and publish a text note (kind 1)
    /// - Parameters:
    ///   - content: Note content
    ///   - replyTo: Optional event ID to reply to
    ///   - keyPair: Key pair to sign with
    func publishTextNote(_ content: String, replyTo: String? = nil, using keyPair: NostrKeyPair) throws {
        var tags: [[String]] = []

        if let replyEventId = replyTo {
            tags.append(["e", replyEventId, "", "reply"])
        }

        let event = try createSignedEvent(kind: 1, content: content, tags: tags, using: keyPair)
        try publishEvent(event)
    }

    /// Create and publish a reaction (kind 7)
    /// - Parameters:
    ///   - eventId: Event ID to react to
    ///   - content: Reaction content (e.g., "+", "❤️", etc.)
    ///   - eventPubkey: Pubkey of the event being reacted to
    ///   - keyPair: Key pair to sign with
    func publishReaction(to eventId: String, content: String = "+", eventPubkey: String, using keyPair: NostrKeyPair) throws {
        let tags: [[String]] = [
            ["e", eventId],
            ["p", eventPubkey]
        ]

        let event = try createSignedEvent(kind: 7, content: content, tags: tags, using: keyPair)
        try publishEvent(event)
    }

    /// Create and publish a zap request (kind 9734)
    /// - Parameters:
    ///   - eventId: Event ID to zap
    ///   - amount: Amount in millisats
    ///   - comment: Optional comment
    ///   - eventPubkey: Pubkey of the event being zapped
    ///   - keyPair: Key pair to sign with
    func publishZapRequest(to eventId: String, amount: Int, comment: String? = nil, eventPubkey: String, using keyPair: NostrKeyPair) throws {
        var tags: [[String]] = [
            ["e", eventId],
            ["p", eventPubkey],
            ["amount", String(amount)]
        ]

        if let comment = comment {
            tags.append(["comment", comment])
        }

        let event = try createSignedEvent(kind: 9734, content: comment ?? "", tags: tags, using: keyPair)
        try publishEvent(event)
    }
}

// MARK: - Nostr Event Errors

enum NostrEventError: Error {
    case serializationFailed
    case incompleteEvent
    case signingFailed
    case publishFailed
}
