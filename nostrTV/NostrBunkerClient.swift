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
    var bunkerRelays: [String] = []
    private var clientKeyPair: NostrKeyPair?
    private var expectedSecret: String?  // For nostrconnect:// flow validation
    private var connectContinuation: CheckedContinuation<Void, Error>?  // For waiting on connect response

    /// Get the client's private key (for session persistence)
    var clientPrivateKeyHex: String? {
        return clientKeyPair?.privateKeyHex
    }

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
        // Clean up any previous connection state before starting fresh
        print("🧹 Cleaning up previous connection state...")

        // Cancel any pending requests from old connection
        for (_, pending) in pendingRequests {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: BunkerError.notConnected)
        }
        pendingRequests.removeAll()

        // Clear old state
        bunkerPubkey = nil
        expectedSecret = nil
        connectContinuation = nil

        // Disconnect old NostrSDK client if exists
        if nostrSDKClient != nil {
            print("   Disconnecting old relay connection...")
            nostrSDKClient = nil
            subscriptionId = nil
        }

        connectionState = .connecting

        // Parse URI (supports both bunker:// and nostrconnect://)
        guard bunkerURI.hasPrefix("nostrconnect://") || bunkerURI.hasPrefix("bunker://") else {
            throw BunkerError.invalidURI("URI must start with nostrconnect:// or bunker://")
        }

        // Parse the URI components
        // For nostrconnect://, the pubkey is OUR client pubkey
        // We extract the relay and secret
        let components = try parseNostrConnectURI(bunkerURI)

        bunkerRelays = components.relays
        expectedSecret = components.secret  // Store for validation

        // Use the keypair from NostrKeyManager (which matches the URI)
        guard let keyPair = keyManager.currentKeyPair else {
            throw BunkerError.notConnected
        }
        clientKeyPair = keyPair

        // Connect to the relays
        try await connectToRelays(components.relays)

        // Subscribe to messages addressed to our client pubkey
        try await subscribeToMessages()

        connectionState = .waitingForScan

        print("🔄 Waiting for signer to scan QR and send connect response...")

        // Actually wait for the signer to send connect response
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectContinuation = continuation

            // Set a timeout (3 minutes for user to scan and approve)
            Task {
                try? await Task.sleep(nanoseconds: 180_000_000_000) // 180 seconds (3 minutes)

                if self.connectContinuation != nil {
                    self.connectContinuation?.resume(throwing: BunkerError.timeout)
                    self.connectContinuation = nil
                    await MainActor.run {
                        self.connectionState = .error("Timeout waiting for signer (3 minutes)")
                    }
                }
            }
        }

        print("✅ Signer connected and secret validated!")
    }

    /// Connect to a bunker using a bunker:// URI (traditional flow for session restoration)
    /// - Parameters:
    ///   - bunkerURI: The bunker URI (bunker://<signer-pubkey>?relay=<url>...)
    ///   - clientPrivateKeyHex: Optional saved client private key for session restoration
    func connect(bunkerURI: String, clientPrivateKeyHex: String? = nil) async throws {
        connectionState = .connecting

        // Parse bunker URI
        let components = try BunkerURIComponents.parse(bunkerURI)

        // In traditional flow, URI contains the SIGNER's pubkey
        bunkerPubkey = components.clientPubkey  // This is actually signer pubkey in bunker://
        bunkerRelays = components.relays

        // Restore saved client keypair if provided, otherwise generate new one
        if let savedPrivateKeyHex = clientPrivateKeyHex {
            // Restore the client keypair from saved session
            do {
                clientKeyPair = try NostrKeyPair(privateKeyHex: savedPrivateKeyHex)
                print("✅ Restored client keypair from session")
            } catch {
                print("⚠️ Failed to restore client keypair, generating new one: \(error.localizedDescription)")
                clientKeyPair = try NostrKeyPair.generate()
            }
        } else if clientKeyPair == nil {
            // Generate ephemeral keypair for this bunker session if not already set
            clientKeyPair = try NostrKeyPair.generate()
            print("✅ Generated new client keypair")
        }

        // Connect to the bunker relays
        try await connectToRelays(components.relays)

        // Subscribe to messages from the bunker
        try await subscribeToMessages()

        connectionState = .waitingForApproval

        print("📡 Connected to bunker (traditional flow)")
    }

    /// Parse nostrconnect:// URI
    private func parseNostrConnectURI(_ uri: String) throws -> (relays: [String], secret: String?) {
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

        var relays: [String] = []
        var secret: String?

        for item in queryItems {
            switch item.name {
            case "relay":
                if let value = item.value {
                    relays.append(value)
                }
            case "secret":
                secret = item.value
            default:
                break
            }
        }

        guard !relays.isEmpty else {
            throw BunkerError.invalidURI("Missing relay parameter")
        }

        return (relays: relays, secret: secret)
    }

    /// Connect to relays for bunker communication
    private func connectToRelays(_ relayURLs: [String]) async throws {
        do {
            // Create NostrSDKClient with the bunker relays
            nostrSDKClient = try NostrSDKClient(relayURLs: relayURLs)

            // Setup message handler
            setupMessageHandler()

            // Connect to the bunker relays
            nostrSDKClient?.connect()

            // Give the connection a moment to establish
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            print("✅ Connected to bunker relays: \(relayURLs)")
        } catch {
            throw BunkerError.connectionFailed("Failed to connect to bunker relays: \(relayURLs) - \(error.localizedDescription)")
        }
    }

    /// Subscribe to kind 24133 events addressed to our client pubkey
    private func subscribeToMessages() async throws {
        guard let clientPubkey = clientKeyPair?.publicKeyHex,
              let nostrSDKClient = nostrSDKClient,
              !bunkerRelays.isEmpty else {
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

        print("📥 Subscribed to bunker messages on \(bunkerRelays) for pubkey \(clientPubkey.prefix(8))...")
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

        nostrSDKClient = nil
        bunkerPubkey = nil
        bunkerRelays = []
        clientKeyPair = nil
        subscriptionId = nil
        connectionState = .disconnected
    }

    // MARK: - NIP-46 Methods

    /// Get the user's public key from the bunker
    func getPublicKey() async throws -> String {
        try await ensureConnected()
        let response = try await sendRequest(method: .getPublicKey, params: [], timeout: 10)
        return response
    }

    /// Sign a Nostr event using the remote signer
    /// - Parameter event: Unsigned event with all fields except id and sig
    /// - Returns: Fully signed event
    func signEvent(_ event: NostrEvent) async throws -> NostrEvent {
        try await ensureConnected()

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

        let response = try await sendRequest(method: .signEvent, params: [jsonString], timeout: 30)

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
        try await ensureConnected()
        _ = try await sendRequest(method: .ping, params: [], timeout: 10)
    }

    // MARK: - RPC Request Handling

    /// Send an RPC request to the bunker
    /// - Parameters:
    ///   - method: The NIP-46 method to call
    ///   - params: Array of string parameters
    ///   - timeout: Timeout in seconds for this request
    /// - Returns: Response string from bunker
    private func sendRequest(method: BunkerMethod, params: [String], timeout: TimeInterval = 30) async throws -> String {
        guard let clientKeyPair = clientKeyPair,
              let bunkerPubkey = bunkerPubkey else {
            throw BunkerError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = BunkerRequest(method: method.rawValue, params: params)
            let requestId = request.id

            // Create timeout task
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))

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

            // If we're actively waiting for a connection AND expecting a secret, validate it
            // Only validate when we have both an active connection attempt and an expected secret
            if let secret = expectedSecret, connectContinuation != nil {
                print("🔑 Validating connection secret...")

                // Check if this response has a result field
                if let result = response.result, !result.isEmpty {
                    // The result should be "ack" or match the secret
                    if result == "ack" || result == secret {
                        print("✅ Secret validated successfully! (result: \(result.prefix(10))...)")
                        expectedSecret = nil  // Clear it after validation

                        // Resume the waiting continuation - connection established!
                        if let continuation = connectContinuation {
                            print("✅ Resuming connect continuation...")
                            connectContinuation = nil
                            continuation.resume()
                        }
                        return  // Don't process as regular response
                    } else {
                        // Only log mismatch, don't fail immediately - might be an old message
                        print("⚠️ Secret mismatch (expected: \(secret.prefix(10))..., got: \(result.prefix(10))...)")
                        print("   Ignoring this message, waiting for correct connect response...")
                        return  // Ignore this message and wait for the right one
                    }
                } else {
                    // No result field or empty result - this is likely an old message, ignore it
                    print("⚠️ Message has no result field - ignoring (likely old message)")
                    return
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

    // MARK: - Session Restoration & Lazy Connection

    /// Restore session state without connecting to relays (lazy reconnection)
    /// Connection will be established on-demand when first RPC call is made
    func restoreFromSession(bunkerPubkey: String, relays: [String], clientPrivateKeyHex: String) throws {
        self.bunkerPubkey = bunkerPubkey
        self.bunkerRelays = relays
        self.clientKeyPair = try NostrKeyPair(privateKeyHex: clientPrivateKeyHex)
        self.connectionState = .disconnected

        print("📦 Session state restored (lazy — will connect on demand)")
    }

    /// Ensure relay connection is established before sending requests
    /// Connects on-demand if not already connected
    private func ensureConnected() async throws {
        // Already connected
        if nostrSDKClient != nil { return }

        guard !bunkerRelays.isEmpty, clientKeyPair != nil else {
            throw BunkerError.notConnected
        }

        print("🔌 Connecting on demand to bunker relays...")
        try await connectToRelays(bunkerRelays)
        try await subscribeToMessages()
        print("✅ On-demand connection established")
    }
}
