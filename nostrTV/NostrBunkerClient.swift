import Foundation
import Combine
import NostrSDK

/// NIP-46 Remote Signer Client
/// Handles bidirectional RPC communication with a remote signer (bunker)
@MainActor
class NostrBunkerClient: ObservableObject, NIP44v2Encrypting {

    // MARK: - Published State

    @Published var connectionState: BunkerConnectionState = .disconnected
    @Published var errorMessage: String?

    // MARK: - Properties

    private let nostrClient: NostrClient
    private let keyManager: NostrKeyManager

    var bunkerPubkey: String?
    var bunkerRelay: String?
    private var clientKeyPair: NostrKeyPair?

    private var pendingRequests: [String: PendingRequest] = [:]

    private var subscriptionId: String?

    // MARK: - Initialization

    init(nostrClient: NostrClient, keyManager: NostrKeyManager) {
        self.nostrClient = nostrClient
        self.keyManager = keyManager

        // Subscribe to bunker messages from NostrClient
        setupMessageHandler()
    }

    // MARK: - Connection Management

    /// Connect to a bunker using a bunker:// URI
    /// - Parameter bunkerURI: The bunker URI (bunker://<pubkey>?relay=<url>...)
    func connect(bunkerURI: String) async throws {
        connectionState = .connecting

        // Parse bunker URI
        let components = try BunkerURIComponents.parse(bunkerURI)

        // This is actually the CLIENT pubkey in the URI, not bunker pubkey
        // The bunker will respond to messages sent to this pubkey
        bunkerPubkey = components.clientPubkey
        bunkerRelay = components.relay

        // Generate ephemeral keypair for this bunker session
        if clientKeyPair == nil {
            clientKeyPair = try NostrKeyPair.generate()
        }

        // Connect to the bunker relay
        try await connectToRelay(components.relay)

        // Subscribe to messages from the bunker
        try await subscribeToMessages()

        connectionState = .waitingForScan
    }

    /// Connect to a specific relay for bunker communication
    private func connectToRelay(_ relayURL: String) async throws {
        // Note: In a production app, you'd want to ensure the relay is connected
        // For now, we'll rely on NostrClient's existing relay connections
        // or add this specific relay if needed

        // Check if relay is already in NostrClient's connections
        // If not, we'd need to add it (NostrClient modification needed)
    }

    /// Subscribe to kind 24133 events addressed to our client pubkey
    private func subscribeToMessages() async throws {
        guard let clientPubkey = clientKeyPair?.publicKeyHex else {
            throw BunkerError.notConnected
        }

        // Subscribe to kind 24133 events with p-tag matching our pubkey
        subscriptionId = "bunker-\(UUID().uuidString.prefix(8))"

        let filter: [String: Any] = [
            "kinds": [24133],
            "#p": [clientPubkey],
            "limit": 10
        ]

        // Note: We would send this subscription request to NostrClient
        // For now, we rely on NostrClient's callback mechanism
        _ = ["REQ", subscriptionId!, filter]
    }

    /// Disconnect from bunker
    func disconnect() {
        // Cancel all pending requests
        for (_, pending) in pendingRequests {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: BunkerError.notConnected)
        }
        pendingRequests.removeAll()

        // Unsubscribe from messages
        if let subId = subscriptionId {
            // Would send ["CLOSE", subId] via NostrClient
            _ = subId
        }

        bunkerPubkey = nil
        bunkerRelay = nil
        clientKeyPair = nil
        subscriptionId = nil
        connectionState = .disconnected
    }

    // MARK: - NIP-46 Methods

    /// Get the user's public key from the bunker
    func getPublicKey() async throws -> String {
        let response = try await sendRequest(method: .getPublicKey, params: [])
        return response
    }

    /// Sign a Nostr event using the remote signer
    /// - Parameter event: Unsigned event with all fields except id and sig
    /// - Returns: Fully signed event
    func signEvent(_ event: NostrEvent) async throws -> NostrEvent {
        // Serialize event to JSON
        let eventDict: [String: Any] = [
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content ?? "",
            "created_at": event.created_at ?? Int(Date().timeIntervalSince1970)
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw BunkerError.invalidResponse
        }

        let response = try await sendRequest(method: .signEvent, params: [jsonString])

        // Parse signed event from response
        guard let responseData = response.data(using: .utf8),
              let signedDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let signedEventData = try? JSONSerialization.data(withJSONObject: signedDict),
              let signedEvent = try? JSONDecoder().decode(NostrEvent.self, from: signedEventData) else {
            throw BunkerError.invalidResponse
        }

        return signedEvent
    }

    /// Ping the bunker to check connectivity
    func ping() async throws {
        _ = try await sendRequest(method: .ping, params: [])
    }

    // MARK: - RPC Request Handling

    /// Send an RPC request to the bunker
    /// - Parameters:
    ///   - method: The NIP-46 method to call
    ///   - params: Array of string parameters
    /// - Returns: Response string from bunker
    private func sendRequest(method: BunkerMethod, params: [String]) async throws -> String {
        guard let clientKeyPair = clientKeyPair,
              let bunkerPubkey = bunkerPubkey else {
            throw BunkerError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = BunkerRequest(method: method.rawValue, params: params)
            let requestId = request.id

            // Create timeout task (30 seconds)
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds

                if self.pendingRequests.removeValue(forKey: requestId) != nil {
                    continuation.resume(throwing: BunkerError.timeout)
                }
            }

            // Store pending request
            let pending = PendingRequest(
                id: requestId,
                method: method.rawValue,
                sentAt: Date(),
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            pendingRequests[requestId] = pending

            // Encrypt and send request
            Task {
                do {
                    // Serialize request to JSON
                    let jsonData = try JSONEncoder().encode(request)
                    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                        throw BunkerError.encryptionFailed
                    }

                    // Create NostrSDK keys for encryption
                    let clientPrivateKey = clientKeyPair.privateKey
                    guard let bunkerPublicKey = PublicKey(hex: bunkerPubkey) else {
                        throw BunkerError.encryptionFailed
                    }

                    // Encrypt with NIP-44 using NostrSDK
                    let encrypted = try self.encrypt(
                        plaintext: jsonString,
                        privateKeyA: clientPrivateKey,
                        publicKeyB: bunkerPublicKey
                    )

                    // Create kind 24133 event
                    let event = try self.nostrClient.createSignedEvent(
                        kind: 24133,
                        content: encrypted,
                        tags: [["p", bunkerPubkey]],
                        using: clientKeyPair
                    )

                    // Publish event
                    try self.nostrClient.publishEvent(event)

                } catch {
                    Task { @MainActor in
                        self.pendingRequests.removeValue(forKey: requestId)
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Message Handling

    /// Setup handler for incoming kind 24133 events
    private func setupMessageHandler() {
        nostrClient.onBunkerMessageReceived = { [weak self] event in
            Task { @MainActor in
                await self?.handleBunkerMessage(event)
            }
        }
    }

    /// Handle incoming bunker message (kind 24133 event)
    private func handleBunkerMessage(_ event: NostrEvent) async {
        do {
            guard let clientKeyPair = clientKeyPair,
                  let senderPubkey = event.pubkey,
                  let encryptedContent = event.content else {
                return
            }

            // Create NostrSDK keys for decryption
            let clientPrivateKey = clientKeyPair.privateKey
            guard let senderPublicKey = PublicKey(hex: senderPubkey) else {
                return
            }

            // Decrypt response with NIP-44 using NostrSDK
            let decrypted = try self.decrypt(
                payload: encryptedContent,
                privateKeyA: clientPrivateKey,
                publicKeyB: senderPublicKey
            )

            // Parse response
            guard let data = decrypted.data(using: .utf8),
                  let response = try? JSONDecoder().decode(BunkerResponse.self, from: data) else {
                print("❌ Failed to parse bunker response")
                return
            }

            // Handle response
            await handleBunkerResponse(response)

        } catch {
            print("❌ Failed to process bunker message: \(error.localizedDescription)")
        }
    }

    /// Handle parsed bunker response
    private func handleBunkerResponse(_ response: BunkerResponse) async {
        guard let pending = pendingRequests.removeValue(forKey: response.id) else {
            print("⚠️ Received response for unknown request: \(response.id)")
            return
        }

        // Cancel timeout
        pending.timeoutTask.cancel()

        // Resume continuation
        if let error = response.error {
            pending.continuation.resume(throwing: BunkerError.remoteError(error))
        } else if let result = response.result {
            pending.continuation.resume(returning: result)

            // If this was a get_public_key response, update connection state
            if pending.method == BunkerMethod.getPublicKey.rawValue {
                connectionState = .connected(userPubkey: result)
            }
        } else {
            pending.continuation.resume(throwing: BunkerError.invalidResponse)
        }
    }
}
