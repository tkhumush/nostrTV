import Foundation
import Testing
@testable import CoveIOS

@Suite(.serialized)
@MainActor
struct ZapInvoiceTests {
    private let recipient = "f67a7093fdd829fae5796250cf0932482b1d7f40900110d0d932b5a7fb37755d"
    private let provider = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    private func stream() -> CoveIOS.Stream {
        CoveIOS.Stream(streamID: "live:room", eventID: nil, title: "Test",
            streaming_url: "https://example.com/live.m3u8", imageURL: nil,
            pubkey: recipient, eventAuthorPubkey: String(repeating: "b", count: 64), profile: nil,
            status: "live", tags: [], createdAt: Date(), viewerCount: 1,
            recording: nil, startsAt: nil, relays: ["wss://stream.example"])
    }

    private func generator(service: [String: Any]? = nil) throws -> (ZapRequestGenerator, InvoiceServer, InvoiceSigningAuth) {
        let client = try NostrSDKClient(relayURLs: [])
        let auth = InvoiceSigningAuth(nostrSDKClient: client, restoreSession: false)
        auth.isAuthenticated = true
        let server = InvoiceServer(service: service ?? ["callback": "https://wallet.example/pay?token=keep", "allowsNostr": true,
            "nostrPubkey": provider, "minSendable": 1000, "maxSendable": 5_000_000, "commentAllowed": 100])
        InvoiceProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvoiceProtocol.self]
        return (ZapRequestGenerator(nostrSDKClient: client, authManager: auth, session: URLSession(configuration: configuration)), server, auth)
    }

    @Test func signsTheAnnouncementCoordinateAndEncodesLNURLAndPlusSigns() async throws {
        let (generator, server, auth) = try generator()
        let invoice = try await generator.generateInvoice(stream: stream(), amount: 21, comment: "One+two & hello", lud16: "host@wallet.example")
        #expect(invoice.sats == 21)
        #expect(invoice.providerPubkey == provider)
        let event = try #require(auth.signed.first)
        #expect(event.tags.contains(["a", "30311:\(String(repeating: "b", count: 64)):live:room"]))
        #expect(event.tags.contains(["p", recipient]))
        #expect(event.tags.contains(["amount", "21000"]))
        let lnurl = try #require(event.tags.first { $0.first == "lnurl" }?.last)
        let decoded = try Bech32.decode(lnurl)
        #expect(String(data: decoded.data, encoding: .utf8) == "https://wallet.example/.well-known/lnurlp/host")
        let request = try #require(server.requests.last)
        let query = try #require(URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "comment" }?.value == "One+two & hello")
        #expect(query.first { $0.name == "token" }?.value == "keep")
        #expect(query.first { $0.name == "lnurl" }?.value == lnurl)
        let json = try #require(query.first { $0.name == "nostr" }?.value?.data(using: .utf8))
        #expect(try JSONDecoder().decode(LegacyNostrEvent.self, from: json).content == "One+two & hello")
    }

    @Test(arguments: [0, -1, Int.max])
    func invalidAmountsNeverReachTheServiceOrSigner(amount: Int) async throws {
        let (generator, server, auth) = try generator()
        await #expect(throws: ZapRequestError.self) {
            try await generator.generateInvoice(stream: stream(), amount: amount, comment: "", lud16: "host@wallet.example")
        }
        #expect(server.requests.isEmpty)
        #expect(auth.signed.isEmpty)
    }

    @Test func unsupportedServiceCannotCreateAnInvoice() async throws {
        let (generator, server, auth) = try generator(service: ["callback": "https://wallet.example/pay", "allowsNostr": false])
        await #expect(throws: ZapRequestError.self) {
            try await generator.generateInvoice(stream: stream(), amount: 21, comment: "", lud16: "host@wallet.example")
        }
        #expect(server.requests.count == 1)
        #expect(auth.signed.isEmpty)
    }

    @Test func acceptsBech32LightningAddresses() throws {
        let address = "https://wallet.example/.well-known/lnurlp/host"
        let lnurl = try Bech32.encode(hrp: "lnurl", data: Data(address.utf8))
        #expect(try ZapRequestGenerator.endpoint(for: lnurl.uppercased()).absoluteString == address)
    }

    @Test func aReceiptMustMatchTheInvoiceAndTheLightningProvider() {
        let invoice = ZapInvoice(bolt11: "lnbc21invoice", sats: 21, providerPubkey: provider, recipientPubkey: recipient)
        var receipt = ZapComment(id: "1", amount: 21000, senderPubkey: recipient, senderName: nil, comment: "",
            timestamp: Date(), streamEventId: nil, bolt11: "LNBC21INVOICE", receiptPubkey: provider)
        #expect(invoice.matches(receipt))
        receipt.receiptPubkey = recipient
        #expect(!invoice.matches(receipt))
        receipt.receiptPubkey = nil
        #expect(!invoice.matches(receipt))
        let otherInvoice = ZapInvoice(bolt11: "lnbc-different", sats: 21, providerPubkey: provider, recipientPubkey: recipient)
        receipt.receiptPubkey = provider
        #expect(!otherInvoice.matches(receipt))
    }
}

private final class InvoiceSigningAuth: NostrAuthManager {
    var signed: [LegacyNostrEvent] = []
    override func signEvent(_ event: LegacyNostrEvent) async throws -> LegacyNostrEvent {
        signed.append(event)
        var signed = event
        signed.id = "request"
        signed.pubkey = "sender"
        signed.sig = "test-signature"
        return signed
    }
}

private final class InvoiceServer {
    let service: [String: Any]
    private let lock = NSLock()
    private var urls: [URL] = []
    var requests: [URL] { lock.withLock { urls } }
    init(service: [String: Any]) { self.service = service }
    func response(for url: URL) throws -> Data {
        lock.withLock { urls.append(url) }
        let response: [String: Any]
        if url.path == "/pay" { response = ["pr": "lnbc21testinvoice"] }
        else { response = service }
        return try JSONSerialization.data(withJSONObject: response)
    }
}

private final class InvoiceProtocol: URLProtocol {
    static var server: InvoiceServer?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "wallet.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let server = Self.server else { throw URLError(.badURL) }
            let data = try server.response(for: url)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
