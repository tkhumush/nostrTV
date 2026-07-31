# nostrTV Code Review Report

## Executive Summary

nostrTV is a SwiftUI/Swift tvOS Nostr client focused on live streaming. The codebase has recently undergone a partial migration to the official `nostr-sdk-ios` via a wrapper class, `NostrSDKClient`, but the legacy custom WebSocket implementation (`NostrClient`) is still present and unused by the main flow. The app currently has two user-facing bugs that are both symptoms of the same underlying architectural problem: **stateful networking objects are being created in multiple places, callbacks are stored as arrays without per-subscription routing, and subscriptions are not reliably re-established after reconnects.**

Bug #14 (remote-signer login does not load the profile until restart) is caused by `NostrAuthManager` owning a *separate* `NostrSDKClient` instance from `StreamViewModel`. The profile/follow-list callbacks are registered only on the auth manager's private client, but that client is not necessarily connected to the same relay pool that actually delivers events. After app restart, `StreamViewModel` subscribes to the same pubkey on its own client, so the profile finally arrives. Bug #15 (relay instability, chat/zaps stop loading) is caused by a fragile reconnection scheme inside `NostrSDKClient`: it detects silence via a 15-second heartbeat and a 60-second dead threshold, resubscribes only a *subset* of known subscriptions (and only by `purpose` string matching), and relies on `StreamActivityManager` re-adding its callbacks after reconnect. Because chat/zap callbacks are stored as arrays and never keyed by subscription ID, any reconnect that happens while a stream is playing will drop the active chat/zap subscription on the floor.

Across the rest of the codebase there are significant architecture and safety issues: a forced-unwrap/forced-try culture in initializers, several `fatalError` calls, a large amount of dead code from the half-completed SDK migration, per-view network managers that create multiple concurrent relay pools, and several retain cycles and strong-reference closures. The project also lacks any meaningful unit tests, and key security-critical logic (event signature verification, zap request construction) is mixed into UI-facing managers.

The highest-priority work is to (1) consolidate the relay pool into a single long-lived client that is injected into all managers, (2) re-implement subscriptions so that handlers are keyed by subscription ID and automatically re-registered after reconnect, (3) fix the bunker/profile flow so that the authenticated user's pubkey is subscribed on the same relay pool, and (4) remove the legacy `NostrClient.swift` and the duplicated event-parsing logic that is currently confusing the codebase.

---

## Bug #14: Remote Signer Profile Loading

### Root Cause

`NostrAuthManager` owns a private `NostrSDKClient` (line 21) that is initialized during `init()` (line 27). When bunker authentication completes, `authenticateWithBunker` calls `fetchUserData(force: true)` (line 177). `fetchUserData` registers two callbacks on the auth manager's private client:

- `addProfileReceivedCallback` (line 112)
- `onFollowListReceived` (line 121)

and then calls `nostrSDKClient.connectAndFetchUserData(pubkey:)` (line 138).

The problem is that **the same user pubkey is already subscribed to by `StreamViewModel` via its own `NostrSDKClient`** (`StreamViewModel.swift` line 82). `StreamViewModel` only wires up `onStreamReceived` and `onDeletionReceived`; it never wires up profile callbacks for the logged-in user. Conversely, `NostrAuthManager` never tells `StreamViewModel`'s client to subscribe to the user profile, and the auth manager's private client is not the one that is actively receiving traffic. After the bunker handshake succeeds, the signer returns the user's pubkey, but nothing ensures that a profile kind-0 event for that pubkey is requested on a relay that the auth manager's client is actually listening to.

Why does it work after restart? On cold launch the `BunkerSession` is restored from `UserDefaults` (lines 33-47), `isAuthenticated` is set to true, and `currentUser` is populated. `ProfileSettingsView.onAppear` (line 250) calls `authManager.fetchUserData()` *again*. By this time `StreamViewModel` has already connected its own client, the global relay pool has delivered a profile event, and the auth manager's private client has finally managed to establish its own subscriptions. The race is resolved by the delay of app launch and the fact that `StreamViewModel` requests user data after login in `updateFollowList` (line 278) only recreates the profile subscription for the combined author list, which *does* include the user follow list after login—but that happens only after the follow list is received and `ContentView.onChange(of: authManager.followList)` fires. The initial profile fetch from `fetchUserData()` therefore often happens before `StreamViewModel` has subscribed.

In short: **there is no shared relay client, and the profile subscription for the authenticated user is not guaranteed to be active on the client that is actually connected at the moment the bunker handshake completes.**

### Affected Files

- `nostrTV/NostrAuthManager.swift` — lines 21, 27, 100-139, 148-181
- `nostrTV/StreamViewModel.swift` — lines 15, 77-100, 278-292
- `nostrTV/BunkerLoginView.swift` — lines 234-246
- `nostrTV/ProfileSettingsView.swift` — line 250
- `nostrTV/ContentView.swift` — lines 567-570

### Recommended Fix

1. **Use a single `NostrSDKClient` instance for the whole app.** Inject it into `NostrAuthManager` and `StreamViewModel` instead of each creating their own. This eliminates the race between "which client is connected?" and "which callback fires?".
2. **After bunker authentication completes, explicitly subscribe to the user profile on the shared client.** `authenticateWithBunker` should call `viewModel.sdkClient.subscribeToUserData(pubkey: userPubkey)` (or equivalent) immediately after setting `currentUser`, and it should register a profile callback on that same shared client.
3. **Store a single source of truth for the authenticated user**, and make the profile subscription reactive: when `currentUser` changes, the shared client should subscribe to kind 0 / kind 3 for that pubkey and route results to both `authManager.currentProfile` and `authManager.followList`.
4. **Do not rely on `fetchUserData(force:)` being called from `ProfileSettingsView.onAppear` to correct a missed fetch.** The fetch must happen deterministically from the auth manager when authentication is established.

### Code Changes Needed

- In `NostrAuthManager`:
  - Replace `private var nostrSDKClient: NostrSDKClient` with an injected shared client.
  - In `authenticateWithBunker`, after setting `currentUser`, call `sharedClient.subscribeToUserData(pubkey: userPubkey)` and register callbacks on the shared client.
  - Remove the private `connectAndFetchUserData` path or make it use the shared client.
- In `StreamViewModel`:
  - Accept the shared `NostrSDKClient` via initializer injection.
  - Add a callback for user profile events and forward them to `authManager` when the event's pubkey matches the current user.
- In `BunkerLoginView`:
  - After `authManager.authenticateWithBunker(...)` returns, ensure the view does not `dismiss()` before the shared client has issued the profile subscription. Move the subscription call into `authenticateWithBunker` itself so it is unavoidable.

---

## Bug #15: Relay Connection Instability

### Root Cause

The new `NostrSDKClient` has a heartbeat (15 s) and a silence threshold (60 s). When silence exceeds the threshold it calls `attemptReconnection()` (`NostrSDKClient.swift` lines 254-279). That method:

1. Disconnects the relay pool.
2. Waits for an exponential-backoff delay.
3. Calls `relayPool.connect()` and then `resubscribeAll()`.

`resubscribeAll` (lines 282-307) restores only subscriptions whose `purpose` string it recognizes: `streams`, `streams-filtered`, `chat-zaps-<aTag>`, and `follow-list-<prefix>`. Several subscription types are explicitly noted as "needs external re-trigger" (lines 297, 303), and the chat/zap resubscription is reconstructed by calling `subscribeToChatAndZaps(aTag:)`, which creates a brand new subscription ID. However, **the actual chat/zap callbacks live in `StreamActivityManager` and are stored in `NostrSDKClient.chatReceivedCallbacks` / `zapReceivedCallbacks` arrays**. When `resubscribeAll` runs, it does not notify `StreamActivityManager` that the subscription ID has changed, and `StreamActivityManager` only closes/re-subscribes when `startListening` or `stopListening` is called. If a reconnect happens while a stream is playing, the old subscription ID is gone, the new subscription is active, but `StreamActivityManager` still thinks it owns the old one.

Furthermore, the legacy `NostrClient` (still in the repo) has **no reconnection logic at all**. Its `listen` method (`NostrClient.swift` lines 180-194) recursively calls itself after receiving a message, but on `failure` it simply `break`s and never reconnects or resubscribes. The comment `// handleReconnect removed (no longer used)` at line 196 confirms that reconnection was deleted. If the app ever falls back to `NostrClient`, a dropped WebSocket means silence forever.

EOSE handling is also broken in both clients. `NostrClient.handleMessage` treats `EOSE` as a silent no-op (line 240). `NostrSDKClient` routes events through `relayPool.events` but does not expose an EOSE stream; its `resubscribeAll` therefore has no way to know when historical replay ends and when live streaming begins. The suspicion in the bug report that "EOSE handling causes subscriptions to silently stop" is partially correct: the absence of EOSE awareness means the client cannot distinguish "subscription finished" from "subscription dropped", so users experience silence and cannot tell whether the relay is idle or dead.

There is also a bug in the reconnection state: `isReconnecting` is reset to `false` immediately after scheduling the reconnect (line 275), not after it succeeds. If the first reconnect fails quickly, a second heartbeat can start a second parallel reconnection attempt.

### Affected Files

- `nostrTV/NostrSDKClient.swift` — lines 202-307, 484-492 (reconnect and resubscribe logic)
- `nostrTV/StreamActivityManager.swift` — lines 41-86, 120-129
- `nostrTV/NostrClient.swift` — lines 180-196 (legacy client, no reconnect)
- `nostrTV/VideoPlayerView.swift` — lines 243-261, 292-310

### Recommended Fix

1. **Key subscriptions by ID, not by global callback arrays.** Replace `chatReceivedCallbacks`, `zapReceivedCallbacks`, and `profileReceivedCallbacks` with dictionaries keyed by subscription ID, or return a subscription token that wraps the handler. When a subscription is created, store `(subscriptionID, filter, handler)`. On reconnect, re-emit every stored `REQ` with the same subscription ID and re-attach the same handler.
2. **Expose EOSE from the SDK client.** Add an EOSE publisher/closure so the app can flush batched historical events and detect when a subscription has completed its backfill.
3. **Make `StreamActivityManager` react to reconnects.** Either observe a `reconnected` publisher from the shared client and re-call `startListening`, or have the shared client preserve subscription state across reconnects so that the manager's callbacks remain valid.
4. **Fix `isReconnecting` race.** Set `isReconnecting = false` only after `relayPool.connect()` succeeds (or after a bounded failure path), and serialize reconnection on a dedicated queue instead of `DispatchQueue.main.asyncAfter`.
5. **Add ping/pong health checks.** The current heartbeat only measures inbound message time. Add an outbound WebSocket ping every 30 s and mark the connection dead if pong is not received within a timeout.
6. **Delete the legacy `NostrClient.swift`.** It is no longer used (REFACTORING.md Phase 4) and its presence is a trap that can be accidentally re-enabled.

### Code Changes Needed

- In `NostrSDKClient`:
  - Replace callback arrays with `[String: (ZapComment) -> Void]` / `[String: (Profile) -> Void]` dictionaries keyed by subscription ID.
  - Add a `RelayPool` EOSE publisher consumer and propagate it to callers.
  - Rewrite `resubscribeAll()` to iterate stored subscription state, not a `purpose` string map.
  - Fix the `isReconnecting` flag lifecycle and add outbound ping/pong.
- In `StreamActivityManager`:
  - Observe reconnect notifications and re-subscribe with the new ID.
  - Store the last used aTag and automatically resubscribe if the connection recovers.
- In `VideoPlayerView`:
  - Ensure `activityManager.stopListening()` is always called on disappear, including when the view is dismissed via the menu button path.

---

## Refactoring Findings

### Architecture

- **CRITICAL — Multiple `NostrSDKClient` instances created across the app**
  - `StreamViewModel` creates one in `init()` (`StreamViewModel.swift:82`).
  - `NostrAuthManager` creates one in `init()` (`NostrAuthManager.swift:27`).
  - `LiveActivityManager.shared` creates one (`LiveActivityManager.swift:20`).
  - `NostrSDKClient.sharedForChat` is a static singleton (`NostrSDKClient.swift:51`).
  - `VideoPlayerView` receives one from `StreamViewModel` but `StreamerProfilePopupView` creates a new one for zap receipts (`StreamerProfilePopupView.swift:332`).
  - This defeats relay-pool sharing, multiplies WebSocket count, and is the direct cause of Bug #14 and much of Bug #15.

- **CRITICAL — Half-completed SDK migration leaves two competing clients**
  - `NostrClient.swift` (1161 lines) is still present and compiled but not used by the main app flow. It contains its own event parsing, WebSocket, signing, and publishing logic that duplicates `NostrSDKClient`.
  - REFACTORING.md Phase 3/4 are incomplete. The legacy client should be removed and `NostrSDKClient` should become the single client.

- **CRITICAL — UI owns network managers instead of dependency injection**
  - `VideoPlayerView` creates a `StreamActivityManager` as a `@StateObject` (`VideoPlayerView.swift:52`).
  - `BunkerLoginView` creates a `NostrBunkerClient` as a `@StateObject` (`BunkerLoginView.swift:22`).
  - `StreamerProfilePopupView` creates a new `NostrSDKClient` inside a button handler.
  - These per-view managers are hard to test and easy to leak. They should be owned by a single app-level coordinator or passed via the environment.

- **MEDIUM — `NostrEventValidator` is both a validator and an admin-config holder**
  - `AdminConfig` is nested inside `NostrEventValidator.swift` (`NostrEventValidator.swift:17-40`). Admin configuration is a domain concern, not a validation concern.
  - `NostrEventValidator` also contains `constructATag`, `parseATag`, `normalizeATag` utilities that are duplicated in `StreamActivityManager`.

- **MEDIUM — `Stream` model stores redundant `aTag` and host-vs-author logic in many places**
  - `Stream.aTag` is computed from `eventAuthorPubkey` (`Stream.swift:44`).
  - `NostrSDKClient.handleLiveStreamEvent` recomputes the same coordinate and assigns `hostPubkey`/`eventAuthorPubkey` separately.
  - `StreamActivityManager` normalizes the aTag again for matching (`StreamActivityManager.swift:230-241`).
  - Consolidate aTag construction/normalization in one place.

- **LOW — `BunkerModels.swift` and `NostrBunkerClient.swift` duplicate URI parsing logic**
  - `BunkerURIComponents.parse(_:)` and `parseNostrConnectURI(_:)` in `NostrBunkerClient` both parse `bunker://`/`nostrconnect://` URIs. Only one should exist.

### State Management

- **CRITICAL — Callback arrays in `NostrSDKClient` are not keyed by subscription**
  - `profileReceivedCallbacks`, `chatReceivedCallbacks`, `zapReceivedCallbacks` are arrays (`NostrSDKClient.swift:143, 153, 156`). Any caller that adds a callback can never cleanly remove only its own callback; `removeActivityCallbacks` wipes all of them. This is exactly the anti-pattern documented in `docs/LIVE_CHAT_ARCHITECTURE.md`.

- **CRITICAL — `@Published` properties are mutated from background queues without `MainActor` in several places**
  - `NostrSDKClient.handleMetadataEvent` dispatches profile callbacks to `DispatchQueue.main.async` (line 743), which is correct.
  - However, `StreamViewModel` receives stream events on `DispatchQueue.main.async` (line 107), which is fine, but `NostrSDKClient.handleRelayListEvent` and `handleFollowListEvent` also dispatch to main.
  - `NostrAuthManager` calls `fetchUserData(force:)` from `authenticateWithBunker` without ensuring the shared client is connected, and the 10-second timeout is scheduled on `DispatchQueue.main.async` (line 129) while the subscription request is issued elsewhere.

- **MEDIUM — `isInitialLoad` is not reset on reconnect or empty fetch**
  - `StreamViewModel.isInitialLoad` is set to `false` only when the first stream arrives (`StreamViewModel.swift:111-113`). If no streams are live, the loading spinner stays forever.

- **MEDIUM — `LiveActivityManager` is both a singleton and an injectable class**
  - It has `static let shared` (`LiveActivityManager.swift:8`) and a public `init(nostrSDKClient:authManager:)` (`LiveActivityManager.swift:26`). The singleton path uses `try!` and is unsafe.
  - `VideoPlayerView` creates an injected instance (`VideoPlayerView.swift:245`) but never uses `shared`, so the singleton is dead code.

- **LOW — `authManager.bunkerClient` is `@Published` but mutated inside async blocks without proper isolation**
  - `restoreBunkerSession` is `@MainActor` and assigns `self.bunkerClient = client`, which is correct.
  - However, `logout` captures `bunkerClient` and then does `Task { @MainActor in client.disconnect() }` (`NostrAuthManager.swift:228-234`). The capture happens before the task; if `bunkerClient` is nilled on main while the task is pending, the captured reference is still valid but the semantics are fragile.

### Memory Safety

- **CRITICAL — `StreamerProfilePopupView.subscribeToZapReceipts` captures `self` strongly inside a callback**
  - Line 433: `sdkClient.addZapReceivedCallback { zapComment in Task { @MainActor [self] in ... } }`.
  - `[self]` creates a strong capture of the `View` struct. SwiftUI views are value types, but the closure is stored on `NostrSDKClient` and escapes. Because `removeActivityCallbacks()` is never called from `StreamerProfilePopupView`, the closure and its captured `self` live until the client is deallocated. Combined with the per-zap `NostrSDKClient` creation, this creates a retain cycle every time the user opens the zap menu.

- **CRITICAL — `NostrBunkerClient.sendRequest` captures `self` strongly in the continuation closure**
  - Line 336: `withCheckedThrowingContinuation { continuation in ... }`. Inside, `pendingRequests[requestId] = pending` stores a `continuation` and a `timeoutTask` that both strongly capture `self` via the closure. `disconnect()` cancels the timeout tasks and resumes continuations, but only if `disconnect` is called; if the view is dismissed without disconnecting, pending requests leak.

- **CRITICAL — `NostrSDKClient.sharedForChat` uses `try!`**
  - `static let sharedForChat: NostrSDKClient = { let client = try! NostrSDKClient(); client.connect(); return client }()` (`NostrSDKClient.swift:51-55`). A failure to initialize the relay pool will crash the app at class-load time.

- **MEDIUM — `StreamViewModel` holds strong references in event closures but uses `[weak self]`**
  - Correctly uses `[weak self]` in `onStreamReceived` (line 106) and `onDeletionReceived` (line 148).
  - However, `handleAdminFollowListReceived` (line 251) and `updateFollowList` (line 278) are instance methods used as closures; if they were ever passed as escaping closures they would capture `self` strongly. Currently they are called inline, so this is a minor concern.

- **MEDIUM — `NostrAuthManager.fetchUserData` adds profile callbacks every time it is called**
  - `addProfileReceivedCallback` appends to an array (`NostrSDKClient.swift:522-524`). If `ProfileSettingsView` appears multiple times, or if the user logs out and back in, duplicate callbacks accumulate and each fires, causing redundant saves to `UserDefaults`.

- **LOW — `ZapChyronView` and `LiveChatView` read `activityManager.updateTrigger` as a view dependency but never write it**
  - This is a hack to force re-render. It works, but it is a smell that the underlying `ObservableObject` notifications are not reliable. If `updateTrigger` overflows (Int) or is not incremented consistently, the UI stalls.

### Error Handling

- **CRITICAL — `fatalError` in `StreamViewModel.init` and `NostrAuthManager.init`**
  - `StreamViewModel.swift:86`: `fatalError("Failed to initialize NostrSDKClient: \(error)")`.
  - `NostrAuthManager.swift:29`: `fatalError("Failed to initialize NostrSDKClient: \(error)")`.
  - A failure to connect to a relay should never crash a user-facing app. It should degrade to an error state.

- **CRITICAL — `try!` in `LiveActivityManager` and previews**
  - `LiveActivityManager.swift:20`: `self.nostrSDKClient = try! NostrSDKClient()`.
  - `LiveChatView.swift:185`, `ZapChyronView.swift:142`, `StreamerProfilePopupView.swift:332`: `try! NostrSDKClient()` in previews/production paths.

- **CRITICAL — Legacy `NostrClient` silently swallows WebSocket send failures**
  - `sendJSON` (`NostrClient.swift:169-178`) ignores the `error` in the completion closure.
  - `listen` treats any `.failure` as a silent `break` (`NostrClient.swift:185-186`).

- **MEDIUM — `NostrSDKClient.connectToRelays` in `NostrBunkerClient` sleeps for 2 seconds and assumes success**
  - `NostrBunkerClient.swift:222`: `try await Task.sleep(nanoseconds: 2_000_000_000)`. There is no actual connection-state check after the sleep; it simply prints success. If the relay is down, the first `sendRequest` will fail with `notConnected`.

- **MEDIUM — `authenticateWithBunker` does not validate that `userPubkey` matches the bunker session**
  - It saves whatever `getPublicKey()` returns as the user's pubkey. A malicious or buggy signer could return any pubkey. Although the signer is trusted in NIP-46, the app should at least verify that the returned pubkey is valid hex.

- **MEDIUM — `BunkerLoginView` sets `bunkerClient.connectionState = .error(...)` on the main actor but the error can fire after the view has been dismissed**
  - The `Task` in `startBunkerFlow` captures `bunkerClient` and `self`. If the user cancels and dismisses while the task is sleeping, the `@Published` state mutation can crash or warn in SwiftUI.

- **LOW — `NostrEventValidator.validateRequiredFields` uses force unwraps**
  - Lines 126-137: `guard event.id != nil, !event.id!.isEmpty`. These force unwraps are guarded, but the style is brittle and repeated.

### Code Quality

- **CRITICAL — Dead code: `NostrClient.swift` and `NostrProfile` are unused in the main flow**
  - REFACTORING.md says Phase 4 is to delete `NostrClient.swift`. Leaving it in the build bloats the app and confuses reviewers.

- **CRITICAL — Significant duplication between `NostrClient` and `NostrSDKClient`**
  - Both parse kind 0, 3, 30311, 9735, 1311, 24133 events.
  - Both have profile cache logic, bolt11 parsing, relay list extraction, and event signing.
  - The duplication is a maintenance hazard and has already produced inconsistencies (e.g., `NostrClient` uses `Int` for created_at; `NostrSDKClient` uses `TimeInterval(event.createdAt)`).

- **MEDIUM — `NostrSDKClient` is a "god object"**
  - It handles connection, subscriptions, profile caching, event parsing for 8+ kinds, event signing, rate limiting, reconnection, and raw message publishing. It should be split into:
    - `RelayPoolClient` (connection/subscription)
    - `ProfileRepository` (cache/fetch)
    - `StreamEventParser`, `ChatEventParser`, `ZapEventParser`
    - `EventPublisher`

- **MEDIUM — Magic strings for `purpose` tags and `aTag` prefixes**
  - `"chat-zaps-"`, `"streams"`, `"streams-filtered"`, `"follow-list-"`, `"user-data-"`, `"profile-"` are hard-coded in `NostrSDKClient` (`lines 292-304`) and `resubscribeAll` (`lines 293-304`). These should be an enum.

- **MEDIUM — `StreamActivityManager` uses `currentStreamATag!` after a guard**
  - Line 82: `subscriptionId = client.subscribeToChatAndZaps(aTag: currentStreamATag!)`. Although the guard at line 48 sets it, the force unwrap is unnecessary.

- **LOW — `ZapRequestGenerator` hard-codes relay hints**
  - `ZapRequestGenerator.swift:44-49` lists the same five relays as the rest of the app. These should come from the shared client's relay list or from the user's NIP-65 relay list.

- **LOW — `ContentView` duplicates stream-to-player profile attachment logic**
  - Lines 470-489 and 513-532 are nearly identical. Extract a helper method.

### Performance

- **CRITICAL — `updateCategorizedStreams()` runs on every stream event and does heavy work on the main thread**
  - `StreamViewModel.swift:374-433` filters, sorts, categorizes, and requests profiles for all streams on `DispatchQueue.main`. With 50-200 streams and frequent metadata updates, this causes frame drops.
  - Move the non-UI work (filtering, sorting, deduplication) to a background actor/queue and only publish the final arrays on main.

- **CRITICAL — `CachedAsyncImage.loadImageIfNeeded` does not cancel in-flight loads when the view disappears or URL changes**
  - `ImageCache.swift:105-126` fires a `Task` and sets `@State` on completion. If the URL changes quickly, multiple tasks can race and update the wrong image.

- **MEDIUM — `NostrSDKClient.handleRelayEvent` validates every event synchronously on the relay pool's queue**
  - `NostrEventValidator.validateWithoutSignature` (line 335) does JSON serialization and tag validation for every event. For high-volume subscriptions this can block the relay reader. Consider validating only kinds that require it or moving validation off the reader queue.

- **MEDIUM — `NostrAuthManager.addProfileReceivedCallback` duplicates saves to `UserDefaults` on every event**
  - Each profile event re-encodes and writes the full profile (`NostrAuthManager.swift:116`). With multiple relays returning the same profile, this causes redundant I/O.

- **LOW — `ZapChyronView` creates a new `Timer` on every `onChange(of: zapComments.count)`**
  - `ZapChyronView.swift:63-64` stops and restarts the timer whenever the count changes. For a busy stream this is frequent and unnecessary; the existing timer can simply read `zapComments.count` on fire.

---

## Prioritized Action Items

1. **Consolidate relay connection into a single shared `NostrSDKClient`**
   - Remove per-manager/client per-view instantiations.
   - Inject the shared client into `StreamViewModel`, `NostrAuthManager`, `LiveActivityManager`, and `VideoPlayerView`.
   - Delete `NostrClient.swift` and all duplicated event parsing/signing code.

2. **Fix subscription routing and reconnect recovery**
   - Replace callback arrays with subscription-ID-keyed handler storage.
   - Persist every active subscription (ID, filter, handler) and re-emit the exact `REQ` after reconnect.
   - Add EOSE handling so historical backfill completes before live processing.
   - Fix the `isReconnecting` flag lifecycle and add outbound ping/pong.

3. **Fix remote-signer profile loading (Bug #14)**
   - After `authenticateWithBunker` sets `currentUser`, subscribe to the user's kind 0 + kind 3 on the shared client.
   - Route the resulting profile and follow list directly into `NostrAuthManager` without waiting for `ProfileSettingsView.onAppear`.
   - Ensure the subscription happens even if `StreamViewModel` has not yet subscribed.

4. **Harden memory management and error handling**
   - Replace `try!`/`fatalError` in initializers with graceful failure and user-facing error states.
   - Audit all escaping closures for `[weak self]` or proper cleanup (`StreamerProfilePopupView`, `NostrBunkerClient`, `StreamActivityManager`).
   - Stop silently swallowing WebSocket send/receive errors.

5. **Refactor `StreamViewModel` for performance**
   - Move stream filtering, sorting, and categorization off the main thread.
   - Throttle profile batch requests.
   - Reset `isInitialLoad` after a timeout if no streams arrive.

6. **Improve code organization**
   - Extract admin config from `NostrEventValidator`.
   - Create a single `ATag` utility / extension instead of duplicated normalization.
   - Replace magic subscription-purpose strings with an enum.
   - Deduplicate the streamer-profile attachment logic in `ContentView`.

7. **Add tests**
   - The only test file contains an empty example test.
   - Add unit tests for `NostrEventValidator`, `Bolt11` amount parsing, `Stream` categorization, `BunkerURIComponents` parsing, and the reconnection/resubscribe logic.

---

*Report generated for nostrTV code review. File and line numbers reference the state of the repository at review time.*
