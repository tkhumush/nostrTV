//
//  NostrClient.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import Foundation

struct NostrEvent: Codable {
    let kind: Int
    let tags: [[String]]
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
    private var session: URLSession!

    var onStreamReceived: ((Stream) -> Void)?
    
    func getProfile(for pubkey: String) -> Profile? {
        return profiles[pubkey]
    }

    func connect() {
        session = URLSession(configuration: .default)
        let relayURLs = [
            URL(string: "wss://relay.snort.social")!,
            URL(string: "wss://relay.tunestr.io")!,
            URL(string: "wss://relay.damus.io")!,
            URL(string: "wss://relay.primal.net")!
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
        let status = extractTagValue("status", from: tagsAny)
        let imageURL = extractTagValue("image", from: tagsAny)
        let pubkey = extractTagValue("p", from: tagsAny) ?? eventDict["pubkey"] as? String

        guard status == "live", let streamID = streamID, let url = streamURL else {
            print("ℹ️ Stream is not live or missing required info")
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

        print("🎥 Stream: \(combinedTitle) | URL: \(url) | Pubkey: \(pubkey ?? "Unknown")")

        // Create stream with pubkey
        let stream = Stream(streamID: streamID, title: combinedTitle, streaming_url: url, imageURL: imageURL, pubkey: pubkey, profile: nil)
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
    
    func disconnect() {
        for (_, task) in webSocketTasks {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTasks.removeAll()
        print("🔌 Disconnected from all relays")
    }
}
