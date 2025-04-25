//
//  Untitled 2.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import Foundation

class NostrClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private let relayURL = URL(string: "wss://relay.snort.social")!

    var onStreamReceived: ((Stream) -> Void)?

    func connect() {
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: relayURL)
        webSocketTask?.resume()
        print("🔌 Connecting to relay...")

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
            return
        }
        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                print("WebSocket receive error: \(error)")
            case .success(let message):
                if case let .string(text) = message {
                    self?.handleMessage(text)
                }
                self?.listen()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 3,
              let event = json[2] as? [String: Any],
              let kind = event["kind"] as? Int,
              kind == 30311,
              let tags = event["tags"] as? [[Any]] else {
            return
        }

        var title: String?
        var summary: String?
        var streamURL: String?
        var streamID: String?
        var status: String?

        for tag in tags {
            guard let key = tag.first as? String else { continue }

            switch key {
            case "title":
                title = tag.dropFirst().first as? String
            case "summary":
                summary = tag.dropFirst().first as? String
            case "streaming", "streaming_url":
                streamURL = tag.dropFirst().first as? String
            case "d":
                streamID = tag.dropFirst().first as? String
            case "status":
                status = tag.dropFirst().first as? String
            default:
                break
            }
        }

        guard status == "live", let streamID = streamID, let url = streamURL else { return }

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

        let stream = Stream(streamID: streamID, title: combinedTitle, streaming_url: url)
        DispatchQueue.main.async {
            self.onStreamReceived?(stream)
        }
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }
}
