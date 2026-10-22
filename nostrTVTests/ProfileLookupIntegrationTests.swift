import Foundation
import Network
import XCTest
@testable import nostrTV

final class ProfileLookupIntegrationTests: XCTestCase {
    private let pubkey = String(repeating: "a", count: 64)

    @MainActor
    func testRateLimitedLookupEventuallySendsInsteadOfLosingPendingBatch() async throws {
        let relay = try MetadataTestRelay(pubkey: pubkey, responseDelay: 0)
        let url = try await relay.start()
        defer { relay.stop() }
        let limiter = RelayRateLimiter(maxRequestsPerSecond: 1)
        XCTAssertTrue(limiter.shouldAllowRequest()) // Saturate the first second.
        let client = try NostrSDKClient(relayURLs: [url.absoluteString], rateLimiter: limiter)
        defer { client.disconnect() }
        let received = expectation(description: "Throttled profile lookup reaches relay and resolves")
        received.assertForOverFulfill = false
        client.addProfileReceivedCallback(forSubscriptionId: "test") { profile in
            if profile.pubkey == self.pubkey { received.fulfill() }
        }
        client.connect()
        client.requestProfiles(for: [pubkey, pubkey.uppercased()])
        await fulfillment(of: [received], timeout: 6)
        XCTAssertEqual(client.getProfile(for: pubkey)?.preferredName, "Resolved person")
    }

    @MainActor
    func testEmptyFastRelayDoesNotCloseLookupBeforeSlowerProfileArrives() async throws {
        let fast = try MetadataTestRelay(pubkey: pubkey, responseDelay: nil)
        let slow = try MetadataTestRelay(pubkey: pubkey, responseDelay: 3.5)
        let first = try await fast.start()
        let second = try await slow.start()
        defer { fast.stop(); slow.stop() }
        let client = try NostrSDKClient(relayURLs: [first.absoluteString, second.absoluteString])
        defer { client.disconnect() }
        let received = expectation(description: "Slower relay can still supply metadata after fast EOSE")
        received.assertForOverFulfill = false
        client.addProfileReceivedCallback(forSubscriptionId: "test") { profile in
            if profile.pubkey == self.pubkey { received.fulfill() }
        }
        client.connect()
        client.requestProfiles(for: [pubkey])
        await fulfillment(of: [received], timeout: 8)
        XCTAssertEqual(client.getProfile(for: pubkey)?.picture, "https://example.com/avatar.jpg")
    }
}

/// A local Nostr relay using real WebSocket framing. It can answer EOSE without
/// metadata or deliver a profile after a configurable delay; no public network.
private final class MetadataTestRelay: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cove.metadata-test-relay")
    private let pubkey: String
    private let responseDelay: TimeInterval?
    private var connections: [NWConnection] = []
    private var closed = Set<String>()

    init(pubkey: String, responseDelay: TimeInterval?) throws {
        self.pubkey = pubkey
        self.responseDelay = responseDelay
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "ws://127.0.0.1:\(self.listener.port!.rawValue)")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let message = try? JSONSerialization.jsonObject(with: data) as? [Any],
               message.count > 1, let id = message[1] as? String {
                if message[0] as? String == "CLOSE" { self.closed.insert(id) }
                if message[0] as? String == "REQ" {
                    if let delay = self.responseDelay {
                        self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, !self.closed.contains(id) else { return }
                            let event: [String: Any] = ["id": String(repeating: "b", count: 64),
                                "pubkey": self.pubkey, "created_at": Int(Date().timeIntervalSince1970),
                                "kind": 0, "tags": [[String]](), "sig": String(repeating: "c", count: 128),
                                "content": "{\"name\":\"Resolved person\",\"picture\":\"https://example.com/avatar.jpg\"}"]
                            self.send(["EVENT", id, event], to: connection)
                            self.send(["EOSE", id], to: connection)
                        }
                    } else { self.send(["EOSE", id], to: connection) }
                }
            }
            self.receive(connection)
        }
    }

    private func send(_ message: [Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let context = NWConnection.ContentContext(identifier: "nostr", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
