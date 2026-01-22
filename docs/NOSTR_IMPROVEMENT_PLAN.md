# Nostr Protocol Improvement Plan for nostrTV

> Generated: 2026-01-21
> Branch: feature/nostr-protocol-improvements
> Based on: NOSTR_AGENTS.md best practices review

## Executive Summary

This document outlines improvements to align nostrTV with Nostr protocol best practices as defined in `NOSTR_AGENTS.md`. The review identified **23 improvements** across 7 categories, prioritized by security impact and implementation complexity.

---

## Table of Contents

1. [Critical Security Issues](#1-critical-security-issues)
2. [Query Efficiency Improvements](#2-query-efficiency-improvements)
3. [Event Validation](#3-event-validation)
4. [Tag Design Improvements](#4-tag-design-improvements)
5. [Connection Resilience](#5-connection-resilience)
6. [NIP Compliance](#6-nip-compliance)
7. [Documentation Requirements](#7-documentation-requirements)

---

## 1. Critical Security Issues

### 1.1 Add Event Signature Verification

**Priority**: CRITICAL
**Files**: `NostrClient.swift:267-301`, `NostrSDKClient.swift`
**Best Practice Reference**: "Nostr Security Model" section

**Current Issue**:
The app accepts all events from relays without validating Schnorr signatures. A malicious relay could serve forged events.

**Implementation**:
```swift
/// Verify event signature per NIP-01
func verifyEventSignature(_ event: NostrEvent) -> Bool {
    guard let id = event.id,
          let pubkey = event.pubkey,
          let sig = event.sig,
          let createdAt = event.created_at,
          let content = event.content else {
        return false
    }

    // Reconstruct the event hash
    let eventArray: [Any] = [0, pubkey, createdAt, event.kind, event.tags, content]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: eventArray, options: [.sortedKeys, .withoutEscapingSlashes]),
          let expectedId = jsonData.sha256().hexString,
          id == expectedId else {
        return false
    }

    // Verify Schnorr signature using secp256k1
    return verifySchnorrSignature(message: id.hexData, signature: sig.hexData, pubkey: pubkey.hexData)
}
```

**Location**: Add to `handleEvent()` before processing any event kind.

---

### 1.2 Add Author Filtering for Addressable Events

**Priority**: CRITICAL
**Files**: `StreamViewModel.swift:185-196`
**Best Practice Reference**: "Addressable Events Security" section

**Current Issue**:
Stream subscriptions (kind 30311) don't filter by author, allowing anyone to publish fake stream metadata with the same d-tag.

**Current Code** (line 194):
```swift
streamsSubscriptionId = nostrSDKClient.subscribeToStreams(limit: 50)
// No author filter - accepts streams from ANYONE
```

**Recommended Change**:
For the Discover feed, filter by admin follow list at the relay level:
```swift
// Efficient: Filter at relay level
streamsSubscriptionId = nostrSDKClient.subscribeToStreams(
    authors: Array(adminFollowList),  // Only trusted streamers
    limit: 50
)
```

**Trade-off Analysis**:
- Current approach (client-side filter): More streams received, higher bandwidth, potential for spam
- Recommended (server-side filter): Fewer events, lower bandwidth, no spam from untrusted sources

---

### 1.3 Secure Admin Pubkey Configuration

**Priority**: HIGH
**Files**: `StreamViewModel.swift:30`
**Best Practice Reference**: "Nostr Security Model" section

**Current Issue**:
```swift
private let adminPubkey = "f67a7093fdd829fae5796250cf0932482b1d7f40900110d0d932b5a7fb37755d"
```
Hardcoded admin pubkey is a single point of failure. If compromised, the entire Discover feed can be poisoned.

**Recommended Implementation**:
```swift
struct AdminConfig {
    // Multiple admins for redundancy
    static let adminPubkeys: Set<String> = [
        "f67a7093fdd829fae5796250cf0932482b1d7f40900110d0d932b5a7fb37755d",  // Primary admin
        // Add backup admins here
    ]

    // Quorum requirement for sensitive operations
    static let quorumRequired = 1

    /// Verify if a pubkey is a trusted admin
    static func isAdmin(_ pubkey: String) -> Bool {
        return adminPubkeys.contains(pubkey.lowercased())
    }
}
```

---

### 1.4 Verify Lightning Address Ownership

**Priority**: HIGH
**Files**: `ZapRequestGenerator.swift`, `NostrClient.swift:606-672`
**Best Practice Reference**: "Lightning Payments (Zaps - NIP-57)" section

**Current Issue**:
Zap requests use the `lud16` from profile metadata without verifying it belongs to the actual stream owner. An attacker could create a fake profile with their own Lightning address.

**Recommended Verification**:
```swift
/// Verify Lightning address matches the stream owner
func verifyLightningAddress(for stream: Stream) async -> Bool {
    guard let pubkey = stream.pubkey,
          let profile = getProfile(for: pubkey),
          let lud16 = profile.lud16 else {
        return false
    }

    // Verify via LNURL callback that the address resolves
    // and optionally verify nostrPubkey in callback response matches
    return await validateLNURLPayRequest(lud16: lud16, expectedPubkey: pubkey)
}
```

---

## 2. Query Efficiency Improvements

### 2.1 Batch Profile Requests

**Priority**: MEDIUM
**Files**: `NostrClient.swift:740-773`
**Best Practice Reference**: "Efficient Query Design" section

**Current Issue**:
Profile requests are sent individually per pubkey:
```swift
// Current: One request per profile (N requests)
let profileReq: [Any] = [
    "REQ",
    "profile-\(pubkey.prefix(8))",
    ["kinds": [0], "authors": [pubkey], "limit": 1]
]
```

**Recommended Batching**:
```swift
/// Batch profile requests for efficiency
func requestProfiles(for pubkeys: [String]) {
    // Deduplicate and filter already cached
    let uncached = pubkeys.filter { getProfile(for: $0) == nil }
    guard !uncached.isEmpty else { return }

    // Batch into groups of 30 (relay-friendly limit)
    let batches = uncached.chunked(into: 30)

    for (index, batch) in batches.enumerated() {
        let profileReq: [Any] = [
            "REQ",
            "profiles-batch-\(index)",
            ["kinds": [0], "authors": batch, "limit": batch.count]
        ]
        // Send single request for multiple profiles
        sendToFirstRelay(profileReq)
    }
}
```

---

### 2.2 Combine Chat and Zap Subscriptions

**Priority**: MEDIUM
**Files**: `ChatConnectionManager.swift`, `NostrSDKClient.swift`
**Best Practice Reference**: "Efficient Query Design" - "Combine kinds" section

**Current Issue**:
Separate subscriptions for chat (kind 1311) and zaps (kind 9735).

**Recommended Combination**:
```swift
// Efficient: Single subscription for both
let filter = Filter(
    kinds: [1311, 9735],  // Both chat and zaps
    tags: ["a": [aTag]],
    limit: 100
)
// Then separate by kind in application code
```

**Note**: NostrSDKClient already does this in some places. Ensure consistency across all chat subscription code paths.

---

### 2.3 Add Rate Limiting for Relay Requests

**Priority**: MEDIUM
**Files**: `NostrClient.swift`
**Best Practice Reference**: "Efficient Query Design" - relay capacity consideration

**Current Issue**:
No rate limiting on profile requests. High volume of streams can trigger excessive relay load.

**Recommended Implementation**:
```swift
class RateLimiter {
    private var requestTimestamps: [Date] = []
    private let maxRequestsPerSecond: Int = 10

    func shouldAllowRequest() -> Bool {
        let now = Date()
        requestTimestamps = requestTimestamps.filter { now.timeIntervalSince($0) < 1.0 }

        if requestTimestamps.count < maxRequestsPerSecond {
            requestTimestamps.append(now)
            return true
        }
        return false
    }
}
```

---

## 3. Event Validation

### 3.1 Implement Event Validator Function

**Priority**: HIGH
**Files**: New file `NostrEventValidator.swift`
**Best Practice Reference**: "Event Validation" section

**Required Validators by Kind**:

| Kind | Required Tags | Required Content | Validation Rules |
|------|--------------|------------------|------------------|
| 0 (Metadata) | none | JSON object | Valid JSON, contains name or display_name |
| 30311 (Live Event) | d, status | any | d-tag present, status is valid enum |
| 1311 (Live Chat) | a | text | a-tag matches 30311:pubkey:d format |
| 9735 (Zap Receipt) | bolt11, description | any | Valid bolt11 invoice, description is valid zap request |

**Implementation**:
```swift
struct NostrEventValidator {
    enum ValidationError: Error {
        case missingRequiredTag(String)
        case invalidTagFormat(String)
        case invalidContent(String)
        case signatureVerificationFailed
    }

    static func validate(_ event: NostrEvent) throws {
        // 1. Verify signature
        guard verifyEventSignature(event) else {
            throw ValidationError.signatureVerificationFailed
        }

        // 2. Kind-specific validation
        switch event.kind {
        case 30311:
            try validateLiveEvent(event)
        case 1311:
            try validateLiveChat(event)
        case 9735:
            try validateZapReceipt(event)
        default:
            break  // No specific validation for other kinds
        }
    }

    private static func validateLiveEvent(_ event: NostrEvent) throws {
        guard event.tags.contains(where: { $0.first == "d" }) else {
            throw ValidationError.missingRequiredTag("d")
        }

        let status = event.tags.first(where: { $0.first == "status" })?[safe: 1]
        let validStatuses = ["live", "ended", "planned"]
        if let status = status, !validStatuses.contains(status) {
            throw ValidationError.invalidTagFormat("status must be: \(validStatuses.joined(separator: ", "))")
        }
    }
}
```

---

### 3.2 Validate Stream aTag Construction

**Priority**: HIGH
**Files**: `NostrClient.swift:319-323`, `ChatManager.swift`
**Best Practice Reference**: "Addressable Events Security" section

**Current Issue**:
Inconsistent use of `p-tag` (host pubkey) vs `event.pubkey` (event author) for aTag construction:
```swift
// Stream event parsing (NostrClient.swift:322-323)
let hostPubkey = extractTagValue("p", from: tagsAny) ?? eventDict["pubkey"] as? String
let eventAuthorPubkey = eventDict["pubkey"] as? String
```

**Problem**: If `p-tag` differs from event author, chat subscriptions may fail to match.

**Recommended Fix**:
Always use `eventAuthorPubkey` for aTag construction since that's what the relay indexes:
```swift
// aTag format: 30311:<event_author_pubkey>:<d-tag>
let aTag = "30311:\(stream.eventAuthorPubkey.lowercased()):\(stream.streamID)"
```

---

## 4. Tag Design Improvements

### 4.1 Use Single-Letter Tags for Queries

**Priority**: MEDIUM
**Best Practice Reference**: "Tag Design Principles" - "Relays only index single-letter tags"

**Current Status**: The app correctly uses single-letter tags (`t`, `a`, `p`, `e`, `d`). No changes needed.

**Verification Checklist**:
- [x] `t` tags for categories/hashtags
- [x] `a` tags for addressable event references
- [x] `p` tags for pubkey references
- [x] `e` tags for event references
- [x] `d` tags for addressable event identifiers

---

### 4.2 Normalize Tag Values for Consistent Lookups

**Priority**: LOW
**Files**: `ChatConnectionManager.swift`, `NostrClient.swift`

**Current Implementation** (good):
```swift
func normalizeATag(_ aTag: String) -> String {
    let parts = aTag.split(separator: ":", maxSplits: 2)
    guard parts.count >= 3 else { return aTag.lowercased() }
    let kind = parts[0]
    let pubkey = parts[1].lowercased()  // Lowercase pubkey
    let dTag = parts[2]
    return "\(kind):\(pubkey):\(dTag)"
}
```

**Recommendation**: Ensure this normalization is applied consistently everywhere aTags are used as dictionary keys.

---

## 5. Connection Resilience

### 5.1 Add Reconnection to Stream Subscriptions

**Priority**: HIGH
**Files**: `StreamViewModel.swift`, `NostrSDKClient.swift`
**Best Practice Reference**: "Connecting to Multiple Relays" section

**Current Issue**:
Only `ChatConnectionManager` has reconnection logic. Stream subscriptions never reconnect if a relay dies.

**Recommended Implementation**:
```swift
extension NostrSDKClient {
    private var reconnectDelay: TimeInterval = 1
    private var isReconnecting: Bool = false

    func handleDisconnection(relay: URL) {
        guard !isReconnecting else { return }
        isReconnecting = true

        Task {
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))

            if !isConnected(to: relay) {
                reconnectDelay = min(reconnectDelay * 2, 30)
                connect(to: relay)
                resubscribeAll()
            } else {
                reconnectDelay = 1
            }
            isReconnecting = false
        }
    }
}
```

---

### 5.2 Send CLOSE Messages on Subscription End

**Priority**: MEDIUM
**Files**: `NostrClient.swift`, `NostrSDKClient.swift`

**Current Issue**:
Subscriptions are not always cleanly closed with CLOSE messages.

**Recommended Fix**:
```swift
func closeSubscription(_ subscriptionId: String) {
    // Always send CLOSE to all relays
    let closeMessage: [Any] = ["CLOSE", subscriptionId]
    for (url, task) in webSocketTasks {
        sendJSON(closeMessage, on: task, relayURL: url)
    }

    // Remove from active subscriptions
    activeSubscriptions.removeValue(forKey: subscriptionId)
}
```

---

### 5.3 Implement Heartbeat for All Connections

**Priority**: MEDIUM
**Files**: `NostrSDKClient.swift`

**Current**: Only ChatConnectionManager has heartbeat monitoring.

**Recommendation**: Add heartbeat to the main NostrSDKClient for all subscriptions:
```swift
class NostrSDKClient {
    private var lastMessageTime: Date = Date()
    private var heartbeatTimer: Timer?

    func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let silence = Date().timeIntervalSince(self.lastMessageTime)
            if silence > 60 {
                self.reconnectAllRelays()
            }
        }
    }
}
```

---

## 6. NIP Compliance

### 6.1 Verify NIP-05 Addresses

**Priority**: LOW
**Files**: `Profile.swift`, new verification code
**Best Practice Reference**: "Common NIPs Reference" - NIP-05

**Current Issue**:
NIP-05 addresses are stored but never verified:
```swift
struct Profile: Codable {
    let nip05: String?  // Stored but not verified
}
```

**Recommended Implementation**:
```swift
struct NIP05Verifier {
    static func verify(nip05: String, pubkey: String) async -> Bool {
        // Parse: user@domain.com
        let parts = nip05.split(separator: "@")
        guard parts.count == 2 else { return false }

        let user = String(parts[0])
        let domain = String(parts[1])

        // Fetch /.well-known/nostr.json?name=user
        guard let url = URL(string: "https://\(domain)/.well-known/nostr.json?name=\(user)") else {
            return false
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let names = json?["names"] as? [String: String]
            return names?[user]?.lowercased() == pubkey.lowercased()
        } catch {
            return false
        }
    }
}
```

---

### 6.2 Add NIP-31 Alt Tags for Custom Events

**Priority**: LOW
**Best Practice Reference**: "Custom Kind Publishing" section

If nostrTV ever publishes custom event kinds, include alt tags:
```swift
// Example for a hypothetical custom event
let tags: [[String]] = [
    ["alt", "nostrTV stream engagement event"],
    // ... other tags
]
```

**Current Status**: nostrTV only publishes standard kinds (1, 7, 9734). No action needed unless custom kinds are added.

---

### 6.3 Respect User Relay Preferences (NIP-65)

**Priority**: MEDIUM
**Files**: `NostrClient.swift:522-549`
**Best Practice Reference**: "Relay Management (NIP-65)" section

**Current Implementation**:
```swift
private func handleRelayListEvent(_ eventDict: [String: Any]) {
    // Extracts r-tags and stores in userRelays
    // But only used after user login
}
```

**Recommendation**:
- Store read/write permissions from r-tag markers
- Use read relays for fetching, write relays for publishing
- Persist user relay preferences across sessions

---

## 7. Documentation Requirements

### 7.1 Create NIP.md Documentation

**Priority**: HIGH
**Best Practice Reference**: "NIP Documentation" section

**Required File**: `/docs/NIP.md`

**Content Template**:
```markdown
# nostrTV Nostr Implementation

## Event Kinds Used

### Kind 0 - User Metadata (NIP-01)
- **Usage**: Profile display (name, picture, Lightning address)
- **Required Fields**: None (all optional)
- **Extensions**: None

### Kind 3 - Contacts (NIP-02)
- **Usage**: Follow list for feed curation
- **Required Fields**: None
- **Extensions**: None

### Kind 1311 - Live Chat Message (NIP-53)
- **Usage**: Real-time chat in live streams
- **Required Tags**: `a` (stream coordinate)
- **Extensions**: None

### Kind 9735 - Zap Receipt (NIP-57)
- **Usage**: Display zap chyron during streams
- **Required Tags**: `bolt11`, `description`
- **Extensions**: None

### Kind 10002 - Relay List Metadata (NIP-65)
- **Usage**: User relay preferences
- **Required Tags**: `r` (relay URLs)
- **Extensions**: None

### Kind 30311 - Live Event (NIP-53)
- **Usage**: Stream discovery and metadata
- **Required Tags**: `d`, `status`
- **Extensions**: None

## Tag Usage

| Tag | Purpose | Indexed | Used In |
|-----|---------|---------|---------|
| a | Addressable event reference | Yes | 1311, 9735 |
| d | Addressable event identifier | Yes | 30311 |
| e | Event reference | Yes | 9734 |
| p | Pubkey reference | Yes | 0, 3, 30311, 9734 |
| t | Hashtag/category | Yes | 30311 |
| r | Relay URL | Yes | 10002 |
| status | Stream status | No | 30311 |
| streaming | Stream URL | No | 30311 |
| image | Thumbnail URL | No | 30311 |
| bolt11 | Lightning invoice | No | 9735 |

## Security Considerations

1. **Event Signatures**: All events SHOULD be verified before processing
2. **Author Filtering**: Addressable events MUST include author in filters
3. **Admin Operations**: Use multi-admin quorum for sensitive operations
4. **Lightning Addresses**: Verify ownership before displaying zap targets
```

---

## Implementation Priority Matrix

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| P0 (Critical) | 1.1 Event Signature Verification | Medium | Security |
| P0 (Critical) | 1.2 Author Filtering for Streams | Low | Security |
| P1 (High) | 1.3 Multi-Admin Configuration | Low | Security |
| P1 (High) | 1.4 Lightning Address Verification | Medium | Security |
| P1 (High) | 3.1 Event Validator | Medium | Data Integrity |
| P1 (High) | 5.1 Stream Reconnection | Medium | Reliability |
| P1 (High) | 7.1 NIP.md Documentation | Low | Maintainability |
| P2 (Medium) | 2.1 Batch Profile Requests | Medium | Performance |
| P2 (Medium) | 2.2 Combined Chat/Zap Subscription | Low | Performance |
| P2 (Medium) | 2.3 Rate Limiting | Low | Stability |
| P2 (Medium) | 3.2 aTag Validation | Low | Data Integrity |
| P2 (Medium) | 5.2 CLOSE Messages | Low | Resource Cleanup |
| P2 (Medium) | 5.3 Heartbeat Monitoring | Medium | Reliability |
| P2 (Medium) | 6.3 NIP-65 Relay Preferences | Medium | UX |
| P3 (Low) | 6.1 NIP-05 Verification | Low | Trust |
| P3 (Low) | 6.2 NIP-31 Alt Tags | Low | Interoperability |

---

## Recommended Implementation Order

### Phase 1: Security Foundation (Week 1)
1. Event signature verification (1.1)
2. Author filtering for streams (1.2)
3. Event validator implementation (3.1)
4. Multi-admin configuration (1.3)

### Phase 2: Reliability (Week 2)
1. Stream subscription reconnection (5.1)
2. Heartbeat monitoring (5.3)
3. CLOSE message cleanup (5.2)
4. aTag validation consistency (3.2)

### Phase 3: Performance (Week 3)
1. Batch profile requests (2.1)
2. Combined subscriptions (2.2)
3. Rate limiting (2.3)

### Phase 4: Polish (Week 4)
1. NIP.md documentation (7.1)
2. NIP-65 relay preferences (6.3)
3. Lightning address verification (1.4)
4. NIP-05 verification (6.1)

---

## Testing Checklist

### Security Tests
- [ ] Forged event with invalid signature is rejected
- [ ] Event from non-followed author is filtered (Discover feed)
- [ ] Fake stream with same d-tag from different author is rejected
- [ ] Zap to unverified Lightning address shows warning

### Performance Tests
- [ ] Profile requests are batched (max 30 per request)
- [ ] Chat + zap events use single subscription
- [ ] Rate limiting prevents relay overload

### Reliability Tests
- [ ] Stream subscription reconnects after network drop
- [ ] Heartbeat detects stale connections
- [ ] CLOSE messages sent on view dismiss

### Compliance Tests
- [ ] NIP-05 addresses are verified before display badge
- [ ] NIP-65 relay preferences are respected
- [ ] All event kinds match NIP specifications

---

*Document Version: 1.0*
*Review Required By: Project Maintainer*
