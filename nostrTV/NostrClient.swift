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

class NostrClient {
    private var webSocketTasks: [URL: URLSessionWebSocketTask] = [:]

    var onStreamReceived: ((Stream) -> Void)?

    func connect() {
        let session = URLSession(configuration: .default)
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

            let req: [Any] = [
                "REQ",
                "live-streams",
                ["kinds": [30311], "limit": 50]
            ]
            sendJSON(req, on: task)
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
        for (_, task) in webSocketTasks {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTasks.removeAll()
        print("🔌 Disconnected from all relays")
    }
}
