//
//  ZapRequestGenerator.swift
//  nostrTV
//
//  Created by Claude Code
//

import Foundation

/// Generates NIP-57 zap requests and payment QR codes
class ZapRequestGenerator {
    private let nostrClient: NostrClient

    init(nostrClient: NostrClient) {
        self.nostrClient = nostrClient
    }

    /// Generate a zap request for a stream and return the lightning invoice URI
    /// - Parameters:
    ///   - stream: The stream to zap
    ///   - amount: Amount in sats
    ///   - comment: Zap comment/message
    ///   - lud16: Lightning address of the recipient
    /// - Returns: Lightning invoice URI for QR code generation
    func generateZapRequest(
        stream: Stream,
        amount: Int,
        comment: String,
        lud16: String,
        keyPair: NostrKeyPair
    ) async throws -> String {
        print("🔧 Generating zap request:")
        print("   Stream: \(stream.title)")
        print("   Amount: \(amount) sats")
        print("   Comment: \(comment)")
        print("   LUD16: \(lud16)")

        // Build tags for the zap request following NIP-57 specification
        var tags: [[String]] = []

        // Add relays (use ALL the relays we're connected to)
        tags.append(["relays",
                     "wss://relay.snort.social",
                     "wss://relay.tunestr.io",
                     "wss://relay.damus.io",
                     "wss://relay.primal.net",
                     "wss://purplepag.es"])

        // Add amount in millisats
        let amountMillisats = amount * 1000
        tags.append(["amount", String(amountMillisats)])

        // Add lnurl tag
        tags.append(["lnurl", lud16])

        // Add recipient pubkey (p tag)
        if let recipientPubkey = stream.pubkey {
            tags.append(["p", recipientPubkey])
        }

        // Add event coordinate (a tag) for kind 30311 live streaming events
        // Format: 30311:<author-pubkey>:<d-tag>
        if let recipientPubkey = stream.pubkey {
            tags.append(["a", "30311:\(recipientPubkey):\(stream.streamID)"])
        }

        // Add kind tag (k tag) to reference the kind of event being zapped
        tags.append(["k", "30311"])

        print("   Tags: \(tags)")

        // Create the zap request event (kind 9734)
        let zapRequestEvent = try nostrClient.createSignedEvent(
            kind: 9734,
            content: comment,
            tags: tags,
            using: keyPair
        )

        print("   ✓ Created zap request event: \(zapRequestEvent.id?.prefix(8) ?? "unknown")")

        // Print our zap request in the same format as the samples for comparison
        print("\n📤 OUR KIND 9734 ZAP REQUEST EVENT:")
        print(String(repeating: "=", count: 60))
        let ourEventDict: [String: Any] = [
            "id": zapRequestEvent.id ?? "",
            "pubkey": zapRequestEvent.pubkey ?? "",
            "created_at": zapRequestEvent.created_at ?? 0,
            "kind": zapRequestEvent.kind,
            "tags": zapRequestEvent.tags,
            "content": zapRequestEvent.content ?? "",
            "sig": zapRequestEvent.sig ?? ""
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: ourEventDict, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
        print(String(repeating: "=", count: 60))

        // Encode the zap request as JSON
        guard let zapRequestJSON = try? encodeZapRequest(zapRequestEvent) else {
            throw ZapRequestError.encodingFailed
        }

        print("   ✓ Encoded zap request JSON")

        // Fetch the callback URL from the lightning address
        let callbackURL = try await fetchLNURLCallback(lud16: lud16)
        print("   ✓ Fetched callback URL: \(callbackURL)")

        // Build the payment request URL
        var components = URLComponents(string: callbackURL)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "amount", value: String(amountMillisats)))
        queryItems.append(URLQueryItem(name: "nostr", value: zapRequestJSON))
        if !comment.isEmpty {
            queryItems.append(URLQueryItem(name: "comment", value: comment))
        }
        components?.queryItems = queryItems

        guard let paymentURL = components?.url else {
            throw ZapRequestError.invalidURL
        }

        print("   ✓ Built payment URL: \(paymentURL.absoluteString.prefix(100))...")

        // Fetch the lightning invoice
        let invoice = try await fetchLightningInvoice(url: paymentURL)
        print("   ✓ Received invoice")

        return "lightning:\(invoice)"
    }

    private func encodeZapRequest(_ event: NostrEvent) throws -> String {
        let eventDict: [String: Any] = [
            "id": event.id ?? "",
            "pubkey": event.pubkey ?? "",
            "created_at": event.created_at ?? 0,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content ?? "",
            "sig": event.sig ?? ""
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: eventDict, options: [.sortedKeys])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ZapRequestError.encodingFailed
        }

        // URL encode the JSON
        guard let encoded = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ZapRequestError.encodingFailed
        }

        return encoded
    }

    private func fetchLNURLCallback(lud16: String) async throws -> String {
        // Parse lightning address (user@domain.com)
        let parts = lud16.split(separator: "@")
        guard parts.count == 2 else {
            throw ZapRequestError.invalidLightningAddress
        }

        let username = String(parts[0])
        let domain = String(parts[1])

        // Build LNURL endpoint
        let lnurlEndpoint = "https://\(domain)/.well-known/lnurlp/\(username)"
        print("   Fetching LNURL data from: \(lnurlEndpoint)")

        guard let url = URL(string: lnurlEndpoint) else {
            throw ZapRequestError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let callback = json?["callback"] as? String else {
            throw ZapRequestError.missingCallback
        }

        // Check if the service supports nostr zaps
        if let allowsNostr = json?["allowsNostr"] as? Bool, !allowsNostr {
            print("   ⚠️ Warning: Service does not explicitly support Nostr zaps")
        }

        return callback
    }

    private func fetchLightningInvoice(url: URL) async throws -> String {
        print("   Fetching invoice from: \(url.absoluteString.prefix(100))...")
        let (data, response) = try await URLSession.shared.data(from: url)

        // Check HTTP status code
        if let httpResponse = response as? HTTPURLResponse {
            print("   HTTP Status: \(httpResponse.statusCode)")

            // Handle HTTP errors
            if httpResponse.statusCode >= 400 {
                if let responseString = String(data: data, encoding: .utf8) {
                    // Check if it's HTML (server error page)
                    if responseString.contains("<!DOCTYPE html>") || responseString.contains("<html") {
                        print("   ❌ Server returned HTML error page (status \(httpResponse.statusCode))")
                        throw ZapRequestError.serverError("Lightning service is temporarily unavailable (HTTP \(httpResponse.statusCode))")
                    }
                    print("   Raw response: \(responseString.prefix(200))")
                }
                throw ZapRequestError.serverError("HTTP error \(httpResponse.statusCode)")
            }
        }

        // Try to parse as JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // If parsing fails, log and throw appropriate error
            if let responseString = String(data: data, encoding: .utf8) {
                print("   Raw response: \(responseString.prefix(200))")
                print("   ❌ Invalid JSON response from server")

                // Check if it's HTML
                if responseString.contains("<!DOCTYPE html>") || responseString.contains("<html") {
                    throw ZapRequestError.serverError("Lightning service returned an error page instead of an invoice")
                }
            }
            throw ZapRequestError.invalidResponse("Unable to parse server response as JSON")
        }

        guard let pr = json["pr"] as? String else {
            // Check for error
            if let reason = json["reason"] as? String {
                print("   ❌ Error from server: \(reason)")
                throw ZapRequestError.serverError(reason)
            }
            if let status = json["status"] as? String, status == "ERROR" {
                let reason = json["reason"] as? String ?? "Unknown error"
                print("   ❌ Error from server: \(reason)")
                throw ZapRequestError.serverError(reason)
            }
            throw ZapRequestError.missingInvoice
        }

        return pr
    }
}

enum ZapRequestError: Error, LocalizedError {
    case encodingFailed
    case invalidURL
    case invalidLightningAddress
    case missingCallback
    case missingInvoice
    case serverError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode zap request"
        case .invalidURL:
            return "Invalid URL"
        case .invalidLightningAddress:
            return "Invalid lightning address format"
        case .missingCallback:
            return "Lightning service did not provide a callback URL"
        case .missingInvoice:
            return "Lightning service did not return an invoice"
        case .serverError(let reason):
            return "Server error: \(reason)"
        case .invalidResponse(let response):
            return "Invalid response from server: \(response)"
        }
    }
}
