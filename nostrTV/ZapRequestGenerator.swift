import Foundation
import NostrSDK

struct ZapInvoice {
    let bolt11: String
    let sats: Int
    let providerPubkey: String
    let recipientPubkey: String
    var uri: String { "lightning:" + bolt11 }
    func matches(_ receipt: ZapComment) -> Bool {
        receipt.receiptPubkey?.lowercased() == providerPubkey.lowercased() &&
            receipt.bolt11?.lowercased() == bolt11.lowercased()
    }
}

/// Shared NIP-57 invoice preparation. Payment approval happens in the user's wallet.
class ZapRequestGenerator {
    private let nostrSDKClient: NostrSDKClient
    private let authManager: NostrAuthManager?
    private let session: URLSession

    init(nostrSDKClient: NostrSDKClient, authManager: NostrAuthManager? = nil, session: URLSession = .shared) {
        self.nostrSDKClient = nostrSDKClient
        self.authManager = authManager
        self.session = session
    }

    func generateZapRequest(stream: Stream, amount: Int, comment: String, lud16: String) async throws -> String {
        try await generateInvoice(stream: stream, amount: amount, comment: comment, lud16: lud16).uri
    }

    func generateInvoice(stream: Stream, amount: Int, comment: String, lud16: String) async throws -> ZapInvoice {
        guard let authManager, authManager.isAuthenticated else { throw ZapRequestError.noSigningMethodAvailable }
        let (millisats, overflow) = amount.multipliedReportingOverflow(by: 1000)
        guard amount > 0, !overflow else { throw ZapRequestError.invalidAmount }
        guard let recipient = stream.pubkey, PublicKey(hex: recipient) != nil,
              let author = stream.eventAuthorPubkey else { throw ZapRequestError.invalidResponse("This stream has no recipient or announcement author.") }
        let endpoint = try Self.endpoint(for: lud16)
        let service: PayService = try await fetch(endpoint)
        guard service.allowsNostr == true, let provider = service.nostrPubkey, PublicKey(hex: provider) != nil else {
            throw ZapRequestError.invalidResponse("This Lightning service does not support Nostr zaps.")
        }
        guard millisats >= (service.minSendable ?? 0), millisats <= (service.maxSendable ?? Int.max) else {
            let minimum = service.minSendable ?? 0
            let minimumSats = minimum / 1000 + (minimum % 1000 == 0 ? 0 : 1)
            throw ZapRequestError.invalidResponse("Choose an amount between \(minimumSats) and \((service.maxSendable ?? Int.max) / 1000) sats.")
        }
        guard let callback = service.callback, var components = URLComponents(string: callback),
              components.scheme?.lowercased() == "https", components.host != nil else { throw ZapRequestError.missingCallback }
        let lnurl = try Bech32.encode(hrp: "lnurl", data: Data(endpoint.absoluteString.utf8))
        let relayCandidates = stream.relays + ["wss://relay.snort.social", "wss://relay.tunestr.io", "wss://relay.damus.io", "wss://relay.primal.net"]
        var seen = Set<String>()
        let relays = relayCandidates.filter { $0.hasPrefix("wss://") && seen.insert($0).inserted }
        var tags = [["relays"] + relays, ["amount", String(millisats)], ["lnurl", lnurl],
                    ["p", recipient], ["a", ATag.construct(pubkey: author, dTag: stream.streamID)], ["k", "30311"]]
        if let eventID = stream.eventID, eventID.count == 64 { tags.append(["e", eventID]) }
        let event = LegacyNostrEvent(kind: 9734, tags: tags, id: nil, pubkey: nil,
                                    created_at: Int(Date().timeIntervalSince1970), content: comment, sig: nil)
        let signed = try await authManager.signEvent(event)
        try Task.checkCancellation()
        let json = try JSONEncoder().encode(signed)
        guard let encoded = String(data: json, encoding: .utf8) else { throw ZapRequestError.encodingFailed }
        var query = (components.queryItems ?? []).filter { !["amount", "nostr", "lnurl", "comment"].contains($0.name) }
        query += [URLQueryItem(name: "amount", value: String(millisats)), URLQueryItem(name: "nostr", value: encoded), URLQueryItem(name: "lnurl", value: lnurl)]
        if !comment.isEmpty, comment.count <= (service.commentAllowed ?? 0) { query.append(URLQueryItem(name: "comment", value: comment)) }
        components.queryItems = query
        // LNURL servers commonly parse query strings as form data; preserve literal plus signs.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ZapRequestError.invalidURL }
        let response: InvoiceResponse = try await fetch(url)
        guard let invoice = response.pr, !invoice.isEmpty,
              ["lnbc", "lntb", "lnbcrt"].contains(where: invoice.lowercased().hasPrefix),
              invoice.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw ZapRequestError.missingInvoice }
        return ZapInvoice(bolt11: invoice, sats: amount, providerPubkey: provider, recipientPubkey: recipient)
    }

    static func endpoint(for address: String) throws -> URL {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("lnurl1") {
            let decoded = try Bech32.decode(address.lowercased())
            guard decoded.hrp == "lnurl", let text = String(data: decoded.data, encoding: .utf8),
                  let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { throw ZapRequestError.invalidLightningAddress }
            return url
        }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !parts[0].contains("/"), !parts[1].contains("/"), !parts[1].contains(":") else { throw ZapRequestError.invalidLightningAddress }
        var components = URLComponents()
        components.scheme = "https"
        components.host = String(parts[1])
        components.path = "/.well-known/lnurlp/" + parts[0]
        guard let url = components.url else { throw ZapRequestError.invalidLightningAddress }
        return url
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ZapRequestError.serverError("Lightning service is unavailable (HTTP \(status)).")
        }
        if let error = try? JSONDecoder().decode(ServiceError.self, from: data), error.status == "ERROR" {
            throw ZapRequestError.serverError(error.reason ?? "Lightning service rejected the request.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ZapRequestError.invalidResponse("Lightning service returned an unreadable response.") }
    }

    private struct PayService: Decodable {
        let callback: String?
        let allowsNostr: Bool?
        let nostrPubkey: String?
        let minSendable: Int?
        let maxSendable: Int?
        let commentAllowed: Int?
    }
    private struct InvoiceResponse: Decodable { let pr: String? }
    private struct ServiceError: Decodable { let status: String?; let reason: String? }
}

enum ZapRequestError: Error, LocalizedError {
    case encodingFailed, invalidURL, invalidLightningAddress, missingCallback, missingInvoice, invalidAmount
    case serverError(String), invalidResponse(String), noSigningMethodAvailable
    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Could not encode the zap request."
        case .invalidURL: return "The Lightning service URL is invalid."
        case .invalidLightningAddress: return "This creator’s Lightning address is invalid."
        case .missingCallback: return "The Lightning service did not provide a secure payment URL."
        case .missingInvoice: return "The Lightning service did not return an invoice."
        case .invalidAmount: return "Enter a valid positive amount in sats."
        case .serverError(let reason), .invalidResponse(let reason): return reason
        case .noSigningMethodAvailable: return "Sign in to send zaps."
        }
    }
}
