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

        // Build tags for the zap request
        var tags: [[String]] = []

        // Add event reference (e tag) if we have an event ID
        if let eventID = stream.eventID {
            tags.append(["e", eventID])
        }

        // Add recipient pubkey (p tag)
        if let recipientPubkey = stream.pubkey {
            tags.append(["p", recipientPubkey])
        }

        // Add stream coordinate (a tag)
        if let pubkey = stream.pubkey {
            let aTag = "30311:\(pubkey):\(stream.streamID)"
            tags.append(["a", aTag])
        }

        // Add amount in millisats
        let amountMillisats = amount * 1000
        tags.append(["amount", String(amountMillisats)])

        // Add relays (use the relays we're connected to)
        tags.append(["relays", "wss://relay.damus.io", "wss://relay.snort.social"])

        print("   Tags: \(tags)")

        // Create the zap request event (kind 9734)
        let zapRequestEvent = try nostrClient.createSignedEvent(
            kind: 9734,
            content: comment,
            tags: tags,
            using: keyPair
        )

        print("   ✓ Created zap request event: \(zapRequestEvent.id?.prefix(8) ?? "unknown")")

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
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let pr = json?["pr"] as? String else {
            // Check for error
            if let reason = json?["reason"] as? String {
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
        }
    }
}
