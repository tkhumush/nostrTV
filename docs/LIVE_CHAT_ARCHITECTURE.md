# Live Chat Architecture Documentation

> This document captures research and implementation plans for reliable live chat in nostrTV.
> Reference this document in future Claude sessions when working on chat features.

## Table of Contents
1. [Current Problem](#current-problem)
2. [Primal iOS Analysis](#primal-ios-analysis)
3. [nostrdb Analysis](#nostrdb-analysis)
4. [Implementation Plan](#implementation-plan)
5. [Key Code Patterns](#key-code-patterns)

---

## Current Problem

### Symptoms
- Chat messages load initially but stop appearing after navigating between streams
- Messages are received by the backend but not rendered in the UI
- Issue compounds with rapid navigation between streams

### Root Causes Identified

1. **Callback Overwriting**: Each `VideoPlayerView` creates its own `ChatManager`, which sets a global callback on `NostrSDKClient.onChatReceived`. When a new view is created, it **overwrites** the previous callback, breaking message routing.

2. **Race Conditions**: The 0.5s subscription delay can cause subscriptions to start after the view has been dismissed.

3. **No Connection State Tracking**: No heartbeat or reconnection logic - if a relay drops, messages stop forever.

4. **No EOSE Handling**: Messages are processed immediately as received, not batched after historical messages complete.

---

## Primal iOS Analysis

> Source: https://github.com/PrimalHQ/primal-ios-app
> Key branches: `live-event-fixes`, `livevideo`

### Architecture Overview

Primal uses a **dual-connection model**:
1. **Primal Cache Server** (`Connection.regular`) - Primary connection for all requests
2. **Nostr Relay Pool** - Secondary fallback for direct Nostr protocol

### Key Files
```
Primal/Scenes/LiveVideoPlayer/LiveVideoChatController.swift  - Main chat controller
Primal/Scenes/LiveVideoPlayer/LiveChatDatasource.swift       - Table data source
Primal/State/CacheServer/Connection.swift                    - Core WebSocket connection
Primal/State/Relays/RelayPool.swift                          - Relay pool management
Primal/State/Managers/LiveEventManager.swift                 - Live event state
```

### Why Primal is 100% Reliable

#### 1. Singleton Connection Pattern
```swift
// Primal - singleton persists across views
Connection.regular.continuousConnectionCancellable(...)

// nostrTV - creates new manager per view (BAD)
@StateObject private var chatManager: ChatManager
```

#### 2. Per-Subscription Handlers (Not Global Callback)
```swift
// Primal - handlers stored by subscription ID
private var subHandlers: [String: (_ result: [JSON], _ relay: String) -> Void] = [:]

func request(_ event: NostrObject, _ handler: @escaping Handler) {
    subHandlers[subscriptionId] = handler  // Isolated, not overwritten
}

// nostrTV - global callback gets overwritten (BAD)
nostrClient.onChatReceived = { [weak self] chatComment in
    // This OVERWRITES any previous callback!
}
```

#### 3. Automatic Cleanup via Weak References
```swift
class ContinuousConnection {
    weak var connection: Connection?

    deinit {
        end()  // Automatically closes when object deallocates
    }
}
```

#### 4. Exponential Backoff Reconnection
```swift
var timeToReconnect: Int = 1  // Starts at 1 second

private func autoReconnect() {
    if isConnected { timeToReconnect = 1; return }
    timeToReconnect = min(timeToReconnect * 2, 30) + 1  // Cap at 30s
    connect()
    dispatchQueue.asyncAfter(deadline: .now() + .seconds(timeToReconnect)) {
        self?.autoReconnect()
    }
}
```

#### 5. Heartbeat Monitoring
```swift
// Consider connection dead after 10 seconds of silence
messageReceived.debounce(for: 10, scheduler: RunLoop.main)
    .map { _ in false }
    .assign(to: \.isConnected, onWeak: self)
```

#### 6. Response Buffering (EOSE Handling)
```swift
private var responseBuffer: [String: [JSON]] = [:]

// Accumulate responses until EOSE
responseBuffer[subscriptionId]?.append(contentsOf: events)

// Process all at once when EOSE received
if isEOSE {
    handler(responseBuffer[subId] ?? [], relay)
}
```

#### 7. Offline Message Queuing
```swift
// Queue messages when disconnected
for unsentEvent in self.unsentEvents.reversed() {
    if unsentEvent.identity == rc.identity {
        rc.request(unsentEvent.event, unsentEvent.callback)
    }
}
```

### Primal's Subscription Lifecycle
```
1. View Appears
   ↓
2. requestChat() - Initial fetch
   ↓
3. continuousConnection established
   ↓
4. Messages stream via callback
   ↓
5. processNewEvent() for each message
   ↓
6. Profile fetched if not cached
   ↓
7. Comment inserted, UI updates
   ↓
8. View Disappears
   ↓
9. continuousConnection.end() called
   ↓
10. CLOSE message sent, cleanup complete
```

---

## nostrdb Analysis

> Source: https://github.com/damus-io/nostrdb
> Created by Damus team, used in production

### What is nostrdb?
- High-performance, embedded Nostr database library
- Uses LMDB (Lightning Memory-Mapped Database) for persistence
- Zero-copy architecture - data accessed directly from memory-mapped files
- ~10,000 lines of C code with custom binary format

### Key Features
- O(1) access to note fields
- Full-text search built-in
- Multi-relay support
- Thread-safe with built-in subscription system
- Persists on disk, survives app restart

### Database Tables (15 total)
```
NDB_DB_NOTE              - Main note storage
NDB_DB_META              - Event metadata
NDB_DB_PROFILE           - User profiles (kind 0)
NDB_DB_NOTE_KIND         - Note kind index
NDB_DB_NOTE_TAGS         - Tag index
NDB_DB_NOTE_PUBKEY       - Author pubkey index
... and more
```

### Swift/iOS Support Status
- **Minimal Swift bindings exist** (`NdbProfile.swift`, `NdbMeta.swift`)
- These are read-only FlatBuffers accessors
- **NO complete Swift wrapper** for core C API
- Would need to write C-Swift interop manually

### Verdict: NOT RECOMMENDED for This Use Case

**Reasons:**
1. **Unstable API** - README explicitly warns of frequent breaking changes
2. **No iOS build documentation** - Must compile from source for tvOS targets
3. **Heavy dependencies** - Requires LMDB, secp256k1, libsodium, flatcc
4. **Overkill for live chat** - Designed for full Nostr client database, not just chat caching
5. **Development overhead** - Would need weeks to properly integrate

**Better Alternative:** Implement Primal's patterns directly in Swift without a caching database. The reliability issues are in connection management, not data persistence.

---

## Implementation Plan

### Phase 1: Connection Architecture Refactor

#### 1.1 Create Singleton ChatConnectionManager
```swift
/// Singleton that manages all chat subscriptions across the app
@MainActor
final class ChatConnectionManager: ObservableObject {
    static let shared = ChatConnectionManager()

    private var subscriptionHandlers: [String: (ZapComment) -> Void] = [:]
    private var activeSubscriptions: [String: String] = [:]  // aTag -> subscriptionID
    private let nostrClient: NostrSDKClient

    private init() {
        // Single callback that routes to appropriate handlers
        nostrClient.onChatReceived = { [weak self] comment in
            self?.routeMessage(comment)
        }
    }

    private func routeMessage(_ comment: ZapComment) {
        guard let streamId = comment.streamEventId else { return }
        let normalizedId = normalizeATag(streamId)
        subscriptionHandlers[normalizedId]?(comment)
    }
}
```

#### 1.2 Per-Stream Subscription Registration
```swift
extension ChatConnectionManager {
    /// Subscribe to chat for a specific stream
    func subscribe(
        aTag: String,
        handler: @escaping (ZapComment) -> Void
    ) -> ChatSubscription {
        let normalized = normalizeATag(aTag)
        subscriptionHandlers[normalized] = handler

        // Create Nostr subscription
        let subId = createSubscription(for: normalized)
        activeSubscriptions[normalized] = subId

        return ChatSubscription(aTag: normalized, manager: self)
    }

    /// Unsubscribe when ChatSubscription is deallocated
    func unsubscribe(aTag: String) {
        let normalized = normalizeATag(aTag)
        subscriptionHandlers.removeValue(forKey: normalized)
        if let subId = activeSubscriptions.removeValue(forKey: normalized) {
            nostrClient.closeSubscription(subId)
        }
    }
}
```

#### 1.3 RAII-Style Subscription Object
```swift
/// Automatically unsubscribes when deallocated (like Primal's ContinuousConnection)
final class ChatSubscription {
    private let aTag: String
    private weak var manager: ChatConnectionManager?

    init(aTag: String, manager: ChatConnectionManager) {
        self.aTag = aTag
        self.manager = manager
    }

    deinit {
        manager?.unsubscribe(aTag: aTag)
    }
}
```

### Phase 2: Connection Resilience

#### 2.1 Connection State Publisher
```swift
extension ChatConnectionManager {
    @Published private(set) var isConnected: Bool = false
    private var lastMessageTime: Date = Date()
    private var heartbeatTimer: Timer?

    func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkConnection()
        }
    }

    private func checkConnection() {
        let silenceDuration = Date().timeIntervalSince(lastMessageTime)
        if silenceDuration > 10 {  // 10 seconds silence = dead connection
            isConnected = false
            reconnect()
        }
    }
}
```

#### 2.2 Exponential Backoff Reconnection
```swift
extension ChatConnectionManager {
    private var reconnectDelay: TimeInterval = 1

    func reconnect() {
        nostrClient.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self = self, !self.isConnected else {
                self?.reconnectDelay = 1  // Reset on success
                return
            }
            self.reconnectDelay = min(self.reconnectDelay * 2, 30)  // Cap at 30s
            self.reconnect()
        }
    }
}
```

### Phase 3: Message Handling

#### 3.1 EOSE-Aware Message Buffering
```swift
extension ChatConnectionManager {
    private var messageBuffers: [String: [ZapComment]] = [:]
    private var eoseReceived: Set<String> = []

    func handleMessage(_ comment: ZapComment, subscriptionId: String) {
        let aTag = normalizeATag(comment.streamEventId ?? "")

        if eoseReceived.contains(subscriptionId) {
            // After EOSE, deliver immediately (real-time message)
            subscriptionHandlers[aTag]?(comment)
        } else {
            // Before EOSE, buffer (historical message)
            messageBuffers[subscriptionId, default: []].append(comment)
        }
    }

    func handleEOSE(subscriptionId: String, aTag: String) {
        eoseReceived.insert(subscriptionId)

        // Deliver all buffered messages at once
        if let buffered = messageBuffers.removeValue(forKey: subscriptionId) {
            for comment in buffered.sorted(by: { $0.timestamp < $1.timestamp }) {
                subscriptionHandlers[aTag]?(comment)
            }
        }
    }
}
```

### Phase 4: View Integration

#### 4.1 Updated ChatManager (Per-View State Only)
```swift
/// Lightweight per-view state, delegates to singleton for subscriptions
@MainActor
class ChatManager: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []

    private var subscription: ChatSubscription?
    private let aTag: String

    init(stream: Stream) {
        guard let pubkey = stream.eventAuthorPubkey else { return }
        self.aTag = "30311:\(pubkey.lowercased()):\(stream.streamID)"
    }

    func startListening() {
        subscription = ChatConnectionManager.shared.subscribe(aTag: aTag) { [weak self] comment in
            self?.handleMessage(comment)
        }
    }

    private func handleMessage(_ comment: ZapComment) {
        let message = ChatMessage(from: comment)
        messages.append(message)
        messages.sort { $0.timestamp < $1.timestamp }
        if messages.count > 50 { messages.removeFirst() }
    }

    deinit {
        // subscription automatically unsubscribes via its deinit
    }
}
```

#### 4.2 Updated VideoPlayerView
```swift
struct VideoPlayerView: View {
    @StateObject private var chatManager: ChatManager

    init(stream: Stream, ...) {
        _chatManager = StateObject(wrappedValue: ChatManager(stream: stream))
    }

    var body: some View {
        // ... existing view code ...
    }
    .onAppear {
        chatManager.startListening()
    }
    // No need for onDisappear cleanup - handled by deinit
}
```

### Phase 5: Testing & Validation

#### 5.1 Test Cases
1. **Basic Flow**: Enter stream → see messages → exit → no crashes
2. **Rapid Navigation**: Enter/exit 10 streams quickly → no orphaned subscriptions
3. **Reconnection**: Disable network → re-enable → messages resume
4. **Multiple Streams**: Open stream A → exit → open stream B → messages route correctly
5. **Memory**: Navigate many streams → memory stays stable (no leaks)

#### 5.2 Debug Logging Points
```swift
// Key points to log for debugging:
print("📡 ChatConnection: Subscribing to \(aTag)")
print("📡 ChatConnection: Handler registered for \(aTag)")
print("📡 ChatConnection: Message routed to \(aTag)")
print("📡 ChatConnection: EOSE received for \(subscriptionId)")
print("📡 ChatConnection: Unsubscribing from \(aTag)")
print("📡 ChatConnection: Connection state: \(isConnected)")
print("📡 ChatConnection: Reconnecting (attempt \(attempt), delay \(delay)s)")
```

---

## Key Code Patterns

### Pattern 1: Normalized aTag Keys
```swift
func normalizeATag(_ aTag: String) -> String {
    let parts = aTag.split(separator: ":", maxSplits: 2)
    guard parts.count >= 3 else { return aTag.lowercased() }
    return "\(parts[0]):\(parts[1].lowercased()):\(parts[2])"
}
```

### Pattern 2: Weak Self in Async Callbacks
```swift
nostrClient.onChatReceived = { [weak self] comment in
    Task { @MainActor in
        self?.handleMessage(comment)
    }
}
```

### Pattern 3: RAII Subscription Cleanup
```swift
class Subscription {
    deinit {
        cleanup()  // Always runs when object deallocates
    }
}
```

### Pattern 4: Connection State with Combine
```swift
@Published private(set) var isConnected: Bool = false

var isConnectedPublisher: AnyPublisher<Bool, Never> {
    $isConnected.eraseToAnyPublisher()
}
```

---

## Summary

### Do This
- Use singleton `ChatConnectionManager` for all subscriptions
- Store handlers per subscription ID (not global callback)
- Implement automatic cleanup via `deinit`
- Add heartbeat monitoring and reconnection
- Buffer messages until EOSE

### Don't Do This
- Create ChatManager per view (causes callback overwriting)
- Use global callback that gets overwritten
- Use arbitrary delays for subscription timing
- Ignore connection state
- Skip EOSE handling

---

## References

- Primal iOS: https://github.com/PrimalHQ/primal-ios-app
- nostrdb: https://github.com/damus-io/nostrdb
- NIP-28 (Public Chat): https://github.com/nostr-protocol/nips/blob/master/28.md
- NIP-53 (Live Activities): https://github.com/nostr-protocol/nips/blob/master/53.md

---

*Last Updated: 2026-01-15*
*Author: Claude Code Analysis*
