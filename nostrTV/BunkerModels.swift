import Foundation

// MARK: - NIP-46 Request/Response Models

/// NIP-46 RPC request structure
/// Sent as encrypted kind 24133 event content
struct BunkerRequest: Codable {
    let id: String
    let method: String
    let params: [String]

    init(id: String = UUID().uuidString, method: String, params: [String] = []) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// NIP-46 RPC response structure
/// Received as encrypted kind 24133 event content
struct BunkerResponse: Codable {
    let id: String
    let result: String?
    let error: String?

    var isSuccess: Bool {
        return error == nil
    }
}

// MARK: - Session Models

/// Represents a persisted bunker session
struct BunkerSession: Codable {
    let bunkerPubkey: String      // Remote signer's public key
    let relay: String              // Relay URL for communication
    var userPubkey: String?        // User's actual Nostr public key (after connect)
    let createdAt: Date
    var lastUsed: Date

    init(bunkerPubkey: String, relay: String, userPubkey: String? = nil, createdAt: Date = Date(), lastUsed: Date = Date()) {
        self.bunkerPubkey = bunkerPubkey
        self.relay = relay
        self.userPubkey = userPubkey
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }
}

/// Bunker connection state
enum BunkerConnectionState: Equatable {
    case disconnected
    case connecting
    case waitingForScan              // QR code displayed, waiting for mobile app to scan
    case waitingForApproval          // Mobile app scanned, waiting for user approval
    case connected(userPubkey: String)
    case error(String)

    static func == (lhs: BunkerConnectionState, rhs: BunkerConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.waitingForScan, .waitingForScan),
             (.waitingForApproval, .waitingForApproval):
            return true
        case (.connected(let lhsPubkey), .connected(let rhsPubkey)):
            return lhsPubkey == rhsPubkey
        case (.error(let lhsMsg), .error(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

// MARK: - Bunker URI Parsing

/// Parsed components of a bunker:// URI
/// Format: bunker://<client-pubkey>?relay=<relay-url>&secret=<secret>&metadata=<json>
struct BunkerURIComponents {
    let clientPubkey: String
    let relay: String
    let secret: String?
    let metadata: [String: String]?

    /// Generate a bunker URI from components (for signer->client flow)
    func toURI() -> String {
        var uri = "bunker://\(clientPubkey)?relay=\(relay)"

        if let secret = secret {
            uri += "&secret=\(secret)"
        }

        if let metadata = metadata,
           let jsonData = try? JSONSerialization.data(withJSONObject: metadata),
           let jsonString = String(data: jsonData, encoding: .utf8),
           let encoded = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            uri += "&metadata=\(encoded)"
        }

        return uri
    }

    /// Generate a nostrconnect URI from components (for client->signer flow / reverse flow)
    func toNostrConnectURI() -> String {
        // URL encode the relay
        let encodedRelay = relay.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relay

        var uri = "nostrconnect://\(clientPubkey)?relay=\(encodedRelay)"

        if let secret = secret {
            uri += "&secret=\(secret)"
        }

        // Add metadata as individual parameters (name, url, etc.)
        if let metadata = metadata {
            for (key, value) in metadata {
                if let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    uri += "&\(key)=\(encodedValue)"
                }
            }
        }

        return uri
    }

    /// Parse a bunker URI string
    static func parse(_ uri: String) throws -> BunkerURIComponents {
        guard uri.hasPrefix("bunker://") else {
            throw BunkerError.invalidURI("URI must start with bunker://")
        }

        let withoutScheme = String(uri.dropFirst(9)) // Remove "bunker://"

        guard let questionMarkIndex = withoutScheme.firstIndex(of: "?") else {
            throw BunkerError.invalidURI("Missing query parameters")
        }

        let pubkey = String(withoutScheme[..<questionMarkIndex])
        let queryString = String(withoutScheme[withoutScheme.index(after: questionMarkIndex)...])

        // Parse query parameters
        var components = URLComponents()
        components.query = queryString

        guard let queryItems = components.queryItems else {
            throw BunkerError.invalidURI("Invalid query parameters")
        }

        var relay: String?
        var secret: String?
        var metadata: [String: String]?

        for item in queryItems {
            switch item.name {
            case "relay":
                relay = item.value
            case "secret":
                secret = item.value
            case "metadata":
                if let metadataString = item.value?.removingPercentEncoding,
                   let metadataData = metadataString.data(using: .utf8),
                   let metadataDict = try? JSONSerialization.jsonObject(with: metadataData) as? [String: String] {
                    metadata = metadataDict
                }
            default:
                break
            }
        }

        guard let relayURL = relay else {
            throw BunkerError.invalidURI("Missing required 'relay' parameter")
        }

        return BunkerURIComponents(
            clientPubkey: pubkey,
            relay: relayURL,
            secret: secret,
            metadata: metadata
        )
    }
}

// MARK: - NIP-46 Methods

/// Supported NIP-46 remote signing methods
enum BunkerMethod: String {
    case connect = "connect"
    case getPublicKey = "get_public_key"
    case signEvent = "sign_event"
    case ping = "ping"
    case disconnect = "disconnect"

    // Extended methods (not implemented yet)
    case nip04Encrypt = "nip04_encrypt"
    case nip04Decrypt = "nip04_decrypt"
    case nip44Encrypt = "nip44_encrypt"
    case nip44Decrypt = "nip44_decrypt"
}

// MARK: - Internal Request Tracking

/// Tracks a pending RPC request awaiting response
struct PendingRequest {
    let id: String
    let method: String
    let sentAt: Date
    let continuation: CheckedContinuation<String, Error>
    let timeoutTask: Task<Void, Never>
}

// MARK: - Errors

enum BunkerError: LocalizedError {
    case invalidURI(String)
    case notConnected
    case timeout
    case invalidResponse
    case remoteError(String)
    case connectionFailed(String)
    case encryptionFailed
    case decryptionFailed
    case unsupportedMethod(String)
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidURI(let details):
            return "Invalid bunker URI: \(details)"
        case .notConnected:
            return "Not connected to bunker"
        case .timeout:
            return "Request timed out after 30 seconds"
        case .invalidResponse:
            return "Invalid response from bunker"
        case .authenticationFailed:
            return "Authentication failed - secret validation error"
        case .remoteError(let msg):
            return "Bunker error: \(msg)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .encryptionFailed:
            return "Failed to encrypt request"
        case .decryptionFailed:
            return "Failed to decrypt response"
        case .unsupportedMethod(let method):
            return "Unsupported method: \(method)"
        }
    }
}
