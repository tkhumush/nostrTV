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

    private var nostrSDKClient: NostrSDKClient?
    private let keyManager: NostrKeyManager

    var bunkerPubkey: String?
    var bunkerRelay: String?
    private var clientKeyPair: NostrKeyPair?
    private var expectedSecret: String?  // For nostrconnect:// flow validation
    private var connectContinuation: CheckedContinuation<Void, Error>?  // For waiting on connect response

    private var pendingRequests: [String: PendingRequest] = [:]

    private var subscriptionId: String?

    // MARK: - Initialization

    init(keyManager: NostrKeyManager) {
        self.keyManager = keyManager
    }

    // MARK: - Connection Management

    /// Wait for signer to connect after scanning nostrconnect:// QR code (reverse flow)
    /// - Parameter nostrConnectURI: The nostrconnect URI we displayed
    func waitForSignerConnection(bunkerURI: String) async throws {
        connectionState = .connecting

        // Parse URI (supports both bunker:// and nostrconnect://)
        guard bunkerURI.hasPrefix("nostrconnect://") || bunkerURI.hasPrefix("bunker://") else {
            throw BunkerError.invalidURI("URI must start with nostrconnect:// or bunker://")
        }

        let isReverseFlow = bunkerURI.hasPrefix("nostrconnect://")

        // Parse the URI components
        // For nostrconnect://, the pubkey is OUR client pubkey
        // We extract the relay and secret
        let components = try parseNostrConnectURI(bunkerURI)

        bunkerRelay = components.relay
        expectedSecret = components.secret  // Store for validation

        // Use the keypair from NostrKeyManager (which matches the URI)
        guard let keyPair = keyManager.currentKeyPair else {
            throw BunkerError.notConnected
        }
        clientKeyPair = keyPair

        // Connect to the relay
        try await connectToRelay(components.relay)

        // Subscribe to messages addressed to our client pubkey
        try await subscribeToMessages()

        connectionState = .waitingForScan

        print("🔄 Waiting for signer to scan QR and send connect response...")

        // Actually wait for the signer to send connect response
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectContinuation = continuation

            // Set a timeout (60 seconds for user to scan and approve)
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds

                if self.connectContinuation != nil {
                    self.connectContinuation?.resume(throwing: BunkerError.timeout)
                    self.connectContinuation = nil
                    await MainActor.run {
                        self.connectionState = .error("Timeout waiting for signer")
                    }
                }
            }
        }

        print("✅ Signer connected and secret validated!")
    }

    /// Connect to a bunker using a bunker:// URI (traditional flow for session restoration)
    /// - Parameter bunkerURI: The bunker URI (bunker://<signer-pubkey>?relay=<url>...)
    func connect(bunkerURI: String) async throws {
        connectionState = .connecting

        // Parse bunker URI
        let components = try BunkerURIComponents.parse(bunkerURI)

        // In traditional flow, URI contains the SIGNER's pubkey
        bunkerPubkey = components.clientPubkey  // This is actually signer pubkey in bunker://
        bunkerRelay = components.relay

        // Generate ephemeral keypair for this bunker session if not already set
        if clientKeyPair == nil {
            clientKeyPair = try NostrKeyPair.generate()
        }

        // Connect to the bunker relay
        try await connectToRelay(components.relay)

        // Subscribe to messages from the bunker
        try await subscribeToMessages()

        connectionState = .waitingForApproval

        print("📡 Connected to bunker (traditional flow)")
    }

    /// Parse nostrconnect:// URI
    private func parseNostrConnectURI(_ uri: String) throws -> (relay: String, secret: String?) {
        let withoutScheme: String
        if uri.hasPrefix("nostrconnect://") {
            withoutScheme = String(uri.dropFirst(15))
        } else if uri.hasPrefix("bunker://") {
            withoutScheme = String(uri.dropFirst(9))
        } else {
            throw BunkerError.invalidURI("Invalid URI scheme")
        }

        guard let questionMarkIndex = withoutScheme.firstIndex(of: "?") else {
            throw BunkerError.invalidURI("Missing query parameters")
        }

        let queryString = String(withoutScheme[withoutScheme.index(after: questionMarkIndex)...])

        // Parse query parameters
        var components = URLComponents()
        components.query = queryString

        guard let queryItems = components.queryItems else {
            throw BunkerError.invalidURI("Invalid query parameters")
        }

        var relay: String?
        var secret: String?

        for item in queryItems {
            switch item.name {
            case "relay":
                relay = item.value
            case "secret":
                secret = item.value
            default:
                break
            }
        }

        guard let relayURL = relay else {
            throw BunkerError.invalidURI("Missing relay parameter")
        }

        return (relay: relayURL, secret: secret)
    }

    /// Connect to a specific relay for bunker communication
    private func connectToRelay(_ relayURL: String) async throws {
        do {
            // Create NostrSDKClient with only the bunker relay
            nostrSDKClient = try NostrSDKClient(relayURLs: [relayURL])

            // Setup message handler
            setupMessageHandler()

            // Connect to the bunker relay
            nostrSDKClient?.connect()

            // Give the connection a moment to establish
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            print("✅ Connected to bunker relay: \(relayURL)")
        } catch {
            throw BunkerError.connectionFailed("Failed to connect to bunker relay: \(relayURL) - \(error.localizedDescription)")
        }
    }

    /// Subscribe to kind 24133 events addressed to our client pubkey
    private func subscribeToMessages() async throws {
        guard let clientPubkey = clientKeyPair?.publicKeyHex,
              let nostrSDKClient = nostrSDKClient,
              let relay = bunkerRelay else {
            throw BunkerError.notConnected
        }

        // Subscribe to kind 24133 events with p-tag matching our pubkey
        subscriptionId = "bunker-\(UUID().uuidString.prefix(8))"

        // Create filter for kind 24133 events with p-tag
        guard let filter = Filter(kinds: [24133], pubkeys: [clientPubkey], limit: 10) else {
            throw BunkerError.connectionFailed("Failed to create subscription filter")
        }

        // Subscribe to bunker messages
        _ = nostrSDKClient.subscribe(with: filter, purpose: "bunker-messages")

        print("📥 Subscribed to bunker messages on \(relay) for pubkey \(clientPubkey.prefix(8))...")
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
                    guard let nostrSDKClient = self.nostrSDKClient else {
                        throw BunkerError.notConnected
                    }

                    // Create signed event using NostrSDKClient's helper method
                    let legacyEvent = try nostrSDKClient.createSignedEvent(
                        kind: 24133,
                        content: encrypted,
                        tags: [["p", bunkerPubkey]],
                        using: clientKeyPair
                    )

                    // Manually publish using the relay pool's send method
                    // Build EVENT message: ["EVENT", <event JSON>]
                    let eventDict: [String: Any] = [
                        "id": legacyEvent.id ?? "",
                        "pubkey": legacyEvent.pubkey ?? "",
                        "created_at": legacyEvent.created_at ?? Int(Date().timeIntervalSince1970),
                        "kind": legacyEvent.kind,
                        "tags": legacyEvent.tags,
                        "content": legacyEvent.content ?? "",
                        "sig": legacyEvent.sig ?? ""
                    ]

                    guard let eventJSON = try? JSONSerialization.data(withJSONObject: eventDict),
                          let eventJSONString = String(data: eventJSON, encoding: .utf8) else {
                        throw BunkerError.encryptionFailed
                    }

                    let eventMessage = "[\"EVENT\",\(eventJSONString)]"
                    nostrSDKClient.publishRawMessage(eventMessage)

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
        nostrSDKClient?.onBunkerMessageReceived = { [weak self] event in
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
                print("⚠️ Missing required fields in bunker message")
                return
            }

            print("📨 Received kind 24133 event from: \(senderPubkey.prefix(8))...")

            // If this is the first message and we don't have bunkerPubkey yet,
            // this is the initial connect response from the signer
            if bunkerPubkey == nil {
                print("📩 First message - setting bunkerPubkey to: \(senderPubkey.prefix(8))...")
                bunkerPubkey = senderPubkey
                connectionState = .waitingForApproval
            }

            // Create NostrSDK keys for decryption
            let clientPrivateKey = clientKeyPair.privateKey
            guard let senderPublicKey = PublicKey(hex: senderPubkey) else {
                print("❌ Invalid signer public key")
                return
            }

            print("🔓 Attempting to decrypt message...")

            // Decrypt response with NIP-44 using NostrSDK
            let decrypted = try self.decrypt(
                payload: encryptedContent,
                privateKeyA: clientPrivateKey,
                publicKeyB: senderPublicKey
            )

            print("✅ Message decrypted successfully")

            // Parse response
            guard let data = decrypted.data(using: .utf8) else {
                print("❌ Could not convert decrypted string to data")
                return
            }

            guard let response = try? JSONDecoder().decode(BunkerResponse.self, from: data) else {
                print("❌ Failed to parse bunker response as BunkerResponse")
                print("📄 Unable to decode response structure")
                return
            }

            print("✅ Parsed response - ID: \(response.id)")

            // If this is a connect response, validate the secret
            if let secret = expectedSecret {
                print("🔑 Validating connection secret...")

                if let result = response.result {
                    // The result should be "ack" or the secret
                    if result != "ack" && result != secret {
                        print("⚠️ Secret validation failed - mismatch detected")
                        connectionState = .error("Secret validation failed")

                        // Resume with error if we're waiting for connection
                        if let continuation = connectContinuation {
                            connectContinuation = nil
                            continuation.resume(throwing: BunkerError.authenticationFailed)
                        }
                        return
                    }
                    print("✅ Secret validated successfully!")
                    expectedSecret = nil  // Clear it after validation

                    // Resume the waiting continuation - connection established!
                    if let continuation = connectContinuation {
                        print("✅ Resuming connect continuation...")
                        connectContinuation = nil
                        continuation.resume()
                    } else {
                        print("⚠️ No connect continuation to resume!")
                    }
                    return  // Don't process as regular response
                } else {
                    print("⚠️ Connect response has no result field!")
                }
            }

            // Handle regular responses
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
