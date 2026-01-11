//
//  ZapRequestGenerator.swift
//  nostrTV
//
//  Created by Claude Code
//

import Foundation

/// Generates NIP-57 zap requests and payment QR codes
class ZapRequestGenerator {
    private let nostrSDKClient: NostrSDKClient
    private let authManager: NostrAuthManager?
    private let verbose: Bool = true  // Set to true for detailed debugging

    init(nostrSDKClient: NostrSDKClient, authManager: NostrAuthManager? = nil) {
        self.nostrSDKClient = nostrSDKClient
        self.authManager = authManager
    }

    /// Generate a zap request for a stream and return the lightning invoice URI
    /// Uses authenticated user (bunker) for signing
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
        lud16: String
    ) async throws -> String {
        // Ensure user is authenticated
        guard let authManager = authManager, authManager.isAuthenticated else {
            throw ZapRequestError.noSigningMethodAvailable
        }

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

        if verbose {
            print("   Tags: \(tags)")
        }

        // Create unsigned event
        let unsignedEvent = NostrEvent(
            kind: 9734,
            tags: tags,
            id: nil,
            pubkey: nil,
            created_at: Int(Date().timeIntervalSince1970),
            content: comment,
            sig: nil
        )

        // Sign with bunker
        let zapRequestEvent = try await authManager.signEvent(unsignedEvent)
        print("   ✓ Signed with authenticated user")

        // Encode the zap request as JSON (without URL encoding - URLQueryItem will handle that)
        let eventDict: [String: Any] = [
            "id": zapRequestEvent.id ?? "",
            "pubkey": zapRequestEvent.pubkey ?? "",
            "created_at": zapRequestEvent.created_at ?? 0,
            "kind": zapRequestEvent.kind,
            "tags": zapRequestEvent.tags,
            "content": zapRequestEvent.content ?? "",
            "sig": zapRequestEvent.sig ?? ""
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: eventDict, options: [])
        guard let zapRequestJSON = String(data: jsonData, encoding: .utf8) else {
            print("   ❌ Failed to encode zap request")
            throw ZapRequestError.encodingFailed
        }

        if verbose {
            print("\n📤 Zap Request Event:")
            print("   ID: \(zapRequestEvent.id?.prefix(16) ?? "unknown")")
            print("   Pubkey: \(zapRequestEvent.pubkey?.prefix(16) ?? "unknown")")
        }

        // Fetch the callback URL from the lightning address
        let callbackURL = try await fetchLNURLCallback(lud16: lud16)

        // Build the payment request URL
        // URLQueryItem will automatically URL-encode the values
        var components = URLComponents(string: callbackURL)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "amount", value: String(amountMillisats)))
        queryItems.append(URLQueryItem(name: "nostr", value: zapRequestJSON))
        if !comment.isEmpty {
            queryItems.append(URLQueryItem(name: "comment", value: comment))
        }
        components?.queryItems = queryItems

        guard let paymentURL = components?.url else {
            print("   ❌ Failed to build payment URL")
            throw ZapRequestError.invalidURL
        }

        if verbose {
            print("   Payment URL: \(paymentURL.absoluteString)")
        }

        // Fetch the lightning invoice
        let invoice = try await fetchLightningInvoice(url: paymentURL)
        print("   ✅ Successfully generated invoice")

        return "lightning:\(invoice)"
    }

    private func fetchLNURLCallback(lud16: String) async throws -> String {
        // Parse lightning address (user@domain.com)
        let parts = lud16.split(separator: "@")
        guard parts.count == 2 else {
            print("   ❌ Invalid Lightning address format: \(lud16)")
            throw ZapRequestError.invalidLightningAddress
        }

        let username = String(parts[0])
        let domain = String(parts[1])

        // Build LNURL endpoint
        let lnurlEndpoint = "https://\(domain)/.well-known/lnurlp/\(username)"

        guard let url = URL(string: lnurlEndpoint) else {
            throw ZapRequestError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let callback = json?["callback"] as? String else {
            print("   ❌ No callback URL in LNURL response")
            throw ZapRequestError.missingCallback
        }

        // Check if the service supports nostr zaps
        if let allowsNostr = json?["allowsNostr"] as? Bool, !allowsNostr {
            print("   ⚠️ Warning: Service may not support Nostr zaps")
        }

        print("   ✓ Got callback URL from \(domain)")
        return callback
    }

    private func fetchLightningInvoice(url: URL) async throws -> String {
        print("   Requesting invoice...")

        // Create URLRequest with timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = 30  // 30 second timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        // Check HTTP status code
        if let httpResponse = response as? HTTPURLResponse {
            if verbose {
                print("   HTTP Status: \(httpResponse.statusCode)")
            }

            // Handle HTTP errors
            if httpResponse.statusCode >= 400 {
                let responseString = String(data: data, encoding: .utf8) ?? ""

                // Check if it's HTML (server error page)
                if responseString.contains("<!DOCTYPE html>") || responseString.contains("<html") {
                    print("   ❌ Lightning service error (HTTP \(httpResponse.statusCode))")
                    throw ZapRequestError.serverError("Lightning service is temporarily unavailable (HTTP \(httpResponse.statusCode))")
                }

                // Try to parse as JSON error
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let reason = json["reason"] as? String {
                    print("   ❌ Lightning service rejected: \(reason)")
                    throw ZapRequestError.serverError(reason)
                }

                print("   ❌ HTTP \(httpResponse.statusCode): \(responseString.prefix(200))")
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
    case noSigningMethodAvailable

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
        case .noSigningMethodAvailable:
            return "No signing method available. Please sign in or provide a keypair."
        }
    }
}
