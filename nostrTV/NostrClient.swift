//
//  Untitled 2.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import Foundation

struct NostrEvent: Codable {
    let kind: Int
    let tags: [[String]]
}

class NostrClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private let relayURL = URL(string: "wss://relay.snort.social")!
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    var onStreamReceived: ((Stream) -> Void)?

    func connect() {
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: relayURL)
        webSocketTask?.resume()
        print("🔌 Connecting to relay \(relayURL)...")

        let req: [Any] = [
            "REQ",
            "live-streams",
            ["kinds": [30311], "limit": 50]
        ]
        sendJSON(req)
        listen()
    }

    private func sendJSON(_ message: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("❌ Failed to serialize message to JSON")
            return
        }
        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("❌ WebSocket send error: \(error)")
            } else {
                print("✅ Sent message: \(jsonString)")
            }
        }
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("❌ WebSocket receive error: \(error)")
                self.handleReconnect()
            case .success(let message):
                if case let .string(text) = message {
                    print("⬅️ Received message: \(text)")
                    self.handleMessage(text)
                }
                self.listen()
            }
        }
    }

    private func handleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("⚠️ Max reconnect attempts reached. Giving up.")
            return
        }
        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts))
        print("🔄 Attempting to reconnect in \(delay) seconds (attempt \(reconnectAttempts))...")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

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
              json.count >= 3,
              let eventDict = json[2] as? [String: Any],
              let kind = eventDict["kind"] as? Int,
              kind == 30311,
              let tagsAny = eventDict["tags"] as? [[Any]] else {
            print("⚠️ Message does not contain expected event data")
            return
        }

        let title = extractTagValue("title", from: tagsAny)
        let summary = extractTagValue("summary", from: tagsAny)
        let streamURL = extractTagValue("streaming", from: tagsAny) ?? extractTagValue("streaming_url", from: tagsAny)
        let streamID = extractTagValue("d", from: tagsAny)
        let status = extractTagValue("status", from: tagsAny)
        let imageURL = extractTagValue("image", from: tagsAny)

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

        print("🎥 Stream: \(combinedTitle) | URL: \(url)")

        let stream = Stream(streamID: streamID, title: combinedTitle, streaming_url: url, imageURL: imageURL)
        DispatchQueue.main.async {
            self.onStreamReceived?(stream)
        }
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        print("🔌 Disconnected from relay")
    }
}
