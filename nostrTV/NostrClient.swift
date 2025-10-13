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

class NostrClient {
    private var webSocketTasks: [URL: URLSessionWebSocketTask] = [:]
    private var profiles: [String: Profile] = [:] // pubkey -> Profile
    private var followListEvents: [String: (timestamp: Int, follows: [String])] = [:] // pubkey -> (created_at, follows)
    private var userRelays: [String] = [] // User's relay list from NIP-65 (kind 10002) or kind 3
    private var session: URLSession!

    var onStreamReceived: ((Stream) -> Void)?
    var onProfileReceived: ((Profile) -> Void)?
    var onFollowListReceived: (([String]) -> Void)?
    var onUserRelaysReceived: (([String]) -> Void)?
    
    func getProfile(for pubkey: String) -> Profile? {
        guard !pubkey.isEmpty else {
            print("⚠️ getProfile called with empty pubkey")
            return nil
        }
        return profiles[pubkey]
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
            print("🔌 Connecting to relay \(url)...")

            // Request live streams
            let streamReq: [Any] = [
                "REQ",
                "live-streams",
                ["kinds": [30311], "limit": 50]
            ]
            sendJSON(streamReq, on: task)

            // Listen for messages
            listen(on: task, from: url)
        }
    }

    private func sendJSON(_ message: [Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("❌ Failed to serialize message to JSON")
            return
        }

        task.send(.string(jsonString)) { error in
            if let error = error {
                print("❌ WebSocket send error: \(error)")
            } else {
                print("✅ Sent message to \(task.originalRequest?.url?.absoluteString ?? "?"): \(jsonString)")
            }
        }
    }

    private func listen(on task: URLSessionWebSocketTask, from relayURL: URL) {
        task.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                print("❌ WebSocket receive error from \(relayURL): \(error)")
            case .success(let message):
                if case let .string(text) = message {
                    print("⬅️ [\(relayURL)] Received message: \(text)")
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
              json.count >= 3 else {
            print("⚠️ Message does not contain expected data format")
            return
        }
        
        // Handle different message types
        if let messageType = json[0] as? String {
            switch messageType {
            case "EVENT":
                handleEvent(json)
            case "EOSE":
                print("🔚 End of stored events for subscription \(json[1] as? String ?? "unknown")")
            case "OK":
                print("✅ Event processed: \(json[1] as? String ?? "unknown")")
            default:
                print("❓ Unknown message type: \(messageType)")
            }
        }
    }
    
    private func handleEvent(_ json: [Any]) {
        guard let eventDict = json[2] as? [String: Any],
              let kind = eventDict["kind"] as? Int else {
            print("⚠️ Event message does not contain expected event data")
            return
        }

        switch kind {
        case 0:
            handleProfileEvent(eventDict)
        case 3:
            handleFollowListEvent(eventDict)
        case 10002:
            handleRelayListEvent(eventDict)
        case 30311:
            handleStreamEvent(eventDict)
        default:
            print("ℹ️ Ignoring event kind: \(kind)")
        }
    }
    
    private func handleStreamEvent(_ eventDict: [String: Any]) {
        guard let tagsAny = eventDict["tags"] as? [[Any]] else {
            print("⚠️ Stream event does not contain tags")
            return
        }

        let title = extractTagValue("title", from: tagsAny)
        let summary = extractTagValue("summary", from: tagsAny)
        let streamURL = extractTagValue("streaming", from: tagsAny) ?? extractTagValue("streaming_url", from: tagsAny)
        let streamID = extractTagValue("d", from: tagsAny)
        let status = extractTagValue("status", from: tagsAny) ?? "unknown"
        let imageURL = extractTagValue("image", from: tagsAny)
        let pubkey = extractTagValue("p", from: tagsAny) ?? eventDict["pubkey"] as? String

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
            print("ℹ️ Stream missing required streamID")
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

        print("🎥 Stream: \(combinedTitle) | Status: \(status) | URL: \(finalStreamURL) | Tags: \(allTags) | Pubkey: \(pubkey ?? "Unknown")")

        // Create stream with all information
        let stream = Stream(
            streamID: streamID,
            title: combinedTitle,
            streaming_url: finalStreamURL,
            imageURL: imageURL,
            pubkey: pubkey,
            profile: nil,
            status: status,
            tags: allTags,
            createdAt: createdAt
        )

        DispatchQueue.main.async {
            self.onStreamReceived?(stream)
        }

        // If we have a pubkey, request the profile if we don't have it
        if let pubkey = pubkey, self.profiles[pubkey] == nil {
            requestProfile(for: pubkey)
        }
    }
    
    private func handleProfileEvent(_ eventDict: [String: Any]) {
        guard let pubkey = eventDict["pubkey"] as? String,
              let content = eventDict["content"] as? String else {
            print("⚠️ Profile event missing required fields")
            return
        }

        // Parse the content as JSON
        guard let data = content.data(using: .utf8),
              let profileData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ Profile content is not valid JSON")
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

        // Store profile
        self.profiles[pubkey] = profile
        print("👤 Profile updated for pubkey: \(pubkey)")

        // Notify callback if set
        DispatchQueue.main.async {
            self.onProfileReceived?(profile)
        }
    }

    private func handleFollowListEvent(_ eventDict: [String: Any]) {
        guard let tagsAny = eventDict["tags"] as? [[Any]],
              let pubkey = eventDict["pubkey"] as? String,
              let createdAt = eventDict["created_at"] as? Int else {
            print("⚠️ Follow list event missing required fields")
            return
        }

        // Check if we already have a follow list for this pubkey
        if let existing = followListEvents[pubkey] {
            // Only process if this event is newer
            if createdAt <= existing.timestamp {
                print("⏭️ Skipping older follow list event (existing: \(existing.timestamp), received: \(createdAt))")
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

        print("📋 Follow list received for \(pubkey.prefix(8))... with \(follows.count) follows (timestamp: \(createdAt))")

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
            print("🔗 Extracted \(relays.count) relays from kind 3 content")
            userRelays = relays

            DispatchQueue.main.async {
                self.onUserRelaysReceived?(relays)
            }
        }
    }

    private func handleRelayListEvent(_ eventDict: [String: Any]) {
        guard let tagsAny = eventDict["tags"] as? [[Any]] else {
            print("⚠️ Relay list event does not contain tags")
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
            print("🔗 Relay list (NIP-65) received with \(relays.count) relays")
            userRelays = relays

            DispatchQueue.main.async {
                self.onUserRelaysReceived?(relays)
            }
        }
    }
    
    private func requestProfile(for pubkey: String) {
        // Send a request for this specific profile
        let profileReq: [Any] = [
            "REQ",
            "profile-\(pubkey.prefix(8))", // Unique subscription ID
            ["kinds": [0], "authors": [pubkey], "limit": 1]
        ]
        
        // Send to all connected relays
        for (_, task) in webSocketTasks {
            sendJSON(profileReq, on: task)
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
            print("🔌 Connecting to relay \(url) for user data...")

            // Request user's relay list (NIP-65, kind 10002) - highest priority
            let relayListReq: [Any] = [
                "REQ",
                "user-relays",
                ["kinds": [10002], "authors": [pubkey], "limit": 1]
            ]
            sendJSON(relayListReq, on: task)

            // Request user profile (kind 0)
            let profileReq: [Any] = [
                "REQ",
                "user-profile",
                ["kinds": [0], "authors": [pubkey], "limit": 1]
            ]
            sendJSON(profileReq, on: task)

            // Request follow list (kind 3) - also contains relay info in content
            // Request multiple events to ensure we get the most recent one across relays
            let followReq: [Any] = [
                "REQ",
                "user-follows",
                ["kinds": [3], "authors": [pubkey], "limit": 10]
            ]
            sendJSON(followReq, on: task)

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

            print("🔄 Reconnecting to user's \(relays.count) personal relays...")

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
            print("⚠️ No valid relay URLs found, staying with default relays")
            return
        }

        for url in relayURLs {
            let task = session.webSocketTask(with: url)
            webSocketTasks[url] = task
            task.resume()
            print("🔌 Connecting to user's relay \(url)...")

            // Request user profile (kind 0) again from user's relays
            let profileReq: [Any] = [
                "REQ",
                "user-profile-personal",
                ["kinds": [0], "authors": [pubkey], "limit": 1]
            ]
            sendJSON(profileReq, on: task)

            // Request follow list (kind 3) from user's relays - most likely to have latest
            let followReq: [Any] = [
                "REQ",
                "user-follows-personal",
                ["kinds": [3], "authors": [pubkey], "limit": 10]
            ]
            sendJSON(followReq, on: task)

            // Listen for messages
            listen(on: task, from: url)
        }
    }

    func disconnect() {
        for (_, task) in webSocketTasks {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTasks.removeAll()
        print("🔌 Disconnected from all relays")
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

        // Serialize to JSON for hashing
        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventForSigning),
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

        print("✍️ Created and signed event: kind=\(kind), id=\(eventId.prefix(8))...")

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

        // Send to all connected relays
        for (url, task) in webSocketTasks {
            sendJSON(message, on: task)
            print("📤 Published event to \(url)")
        }
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
