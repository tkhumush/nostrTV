# nostrTV Refactoring Plan

## Context

nostrTV is a ~3,500-line tvOS app (42 Swift files) that discovers Nostr live streams and plays them with chat and Lightning zap support. The codebase grew organically and is mid-migration from a custom WebSocket client (`NostrClient`) to the official NostrSDK (`NostrSDKClient`). This migration left behind duplicated logic, parallel implementations, and inconsistent patterns. The goal of this refactoring is to reduce duplication, clarify ownership of concerns, remove dead code, and fix thread-safety issues — all without changing external behavior.

---

## Phase 1: Extract Hardcoded Constants

**Objective:** Eliminate magic numbers and duplicated literals so values are defined once and easy to find.

**What changes:**
- Create `nostrTV/Constants.swift` with:
  - `RelayConfig.defaultRelays: [String]` — the 5 relay URLs currently duplicated in `NostrClient.swift:143-148`, `NostrClient.swift:779-784`, and `ZapRequestGenerator.swift:44-49`
  - `CacheConfig` — `maxProfileCacheSize` (500), `profileCacheTTL` (24h), `maxStreamCount` (200), `maxMessages` (50), `maxZaps` (50), `imageCacheCountLimit` (100), `imageCacheSizeLimit` (50MB)
  - `TimeoutConfig` — profile request timeout (30s), stream validation timeout (15s), fetch timeout (10s), presence interval (60s), heartbeat interval (5s), connection timeout (15s)
  - `AdminConfig.primaryAdmin` — the admin pubkey currently in `NostrEventValidator.swift:21` (already referenced via `AdminConfig` in `StreamViewModel.swift:31`, but definition needs to be found/consolidated)
- Replace all inline literals with references to these constants
- Remove the `verbose` flag in `ZapRequestGenerator.swift:14` (always true, serves no purpose)

**Files modified:** `NostrClient.swift`, `NostrSDKClient.swift`, `ZapRequestGenerator.swift`, `StreamViewModel.swift`, `StreamActivityManager.swift`, `ChatManager.swift`, `ZapManager.swift`, `ImageCache.swift`, `ChatConnectionManager.swift`
**Files created:** `nostrTV/Constants.swift`

---

## Phase 2: Remove Dead Code and Stubs

**Objective:** Reduce noise so every line in the codebase is reachable and meaningful.

**What changes:**
- Remove the `// handleReconnect removed` comment at `NostrClient.swift:196`
- Remove `presenceTimer` declaration at `VideoPlayerView.swift:24` — it is declared as `@State` but the `startPresenceTimer()` method at line 345 creates a *new* `Timer.scheduledTimer` that captures `self`, so the `@State` binding is overwritten and never used for SwiftUI state tracking. The timer variable should be a plain instance variable or the method should assign to the `@State` var properly. Since the timer is only used in `onDisappear` to invalidate, keep it but fix the pattern (use the `@State` var consistently)
- Remove `LiveActivityManager.shared` singleton at `LiveActivityManager.swift:8` — it uses `try!` and is never referenced; only the `init(nostrSDKClient:authManager:)` initializer is used (from `VideoPlayerView.swift:245`)
- Remove `LiveActivityManager.configure(with:)` at `LiveActivityManager.swift:32-35` — empty method body, never called
- Remove `NostrKeyPair.verify()` stub at `NostrKeyPair.swift:114` — returns `false` unconditionally, never called
- Remove `TypeMessageButton` at `VideoPlayerView.swift:515-533` — private struct, never instantiated
- Remove the `sendJoinChatMessage` method at `LiveActivityManager.swift:143-169` — fully commented out at call site (line 88-93), method is dead code
- Remove kind 9734 debug print block at `NostrClient.swift:274-282` — raw event dumping, not useful in production
- Remove `ChatManager.getMessagesForStream(_:)` at `ChatManager.swift:108-110` — always returns `messages` regardless of parameter, never called externally
- Clean up excessive `print()` statements: keep error prints (`❌`), remove routine status prints that add no diagnostic value (there are ~80+ print statements across the codebase; reduce to ~20 meaningful ones)

**Files modified:** `NostrClient.swift`, `VideoPlayerView.swift`, `LiveActivityManager.swift`, `NostrKeyPair.swift`, `ChatManager.swift`, plus ~15 files for print cleanup

---

## Phase 3: Deduplicate normalizeATag and Profile Cache

**Objective:** Consolidate the two most duplicated pieces of logic so changes happen in one place.

**What changes:**

**3a. normalizeATag:**
- The identical `normalizeATag(_:)` function exists in three places:
  - `ChatConnectionManager.swift:240-251`
  - `StreamActivityManager.swift:204-215`
  - `ChatManager.swift:184-195`
- Move to a free function in a small utility file or as a `static` method on a shared type (e.g., `Stream` or a new `NostrUtils` enum)
- Replace all three call sites

**3b. Profile cache:**
- `NostrClient.swift` (lines 37-139) and `NostrSDKClient.swift` (lines 49-89+) both implement `ProfileCacheEntry`, `evictOldProfilesIfNeeded()`, and identical cache read/write logic
- Extract into a standalone `ProfileCache` actor:
  - `func getProfile(for pubkey: String) -> Profile?`
  - `func cacheProfile(_ profile: Profile, for pubkey: String)`
  - Internal LRU eviction using `CacheConfig` constants from Phase 1
- Both `NostrClient` and `NostrSDKClient` delegate to this shared cache
- This also fixes the thread-safety issue in `NostrClient` where `profileQueue.sync {}` followed by `profileQueue.async(flags: .barrier)` can produce stale reads

**Files modified:** `ChatConnectionManager.swift`, `StreamActivityManager.swift`, `ChatManager.swift`, `NostrClient.swift`, `NostrSDKClient.swift`
**Files created:** `nostrTV/ProfileCache.swift` (or combined utility file)

---

## Phase 4: Resolve Callback Overwriting in NostrSDKClient

**Objective:** Fix the bug where multiple components overwrite each other's callbacks, causing lost messages.

**What changes:**
- Currently `NostrSDKClient` has single callback properties: `onChatReceived`, `onZapReceived`, `onStreamReceived`, etc.
- Both `StreamActivityManager.startListening()` (line 58) and `ChatConnectionManager.configure()` (line 84) overwrite `onChatReceived` — whichever runs last wins, the other stops receiving messages
- Similarly, `StreamActivityManager` (line 64) and `ZapManager` (line 26) both overwrite `onZapReceived`
- Convert single callbacks to arrays (like `profileReceivedCallbacks` already does at `NostrClient.swift:58`):
  - `onChatReceived` → `addChatReceivedCallback(_:) -> UUID` + `removeChatReceivedCallback(_:)`
  - `onZapReceived` → `addZapReceivedCallback(_:) -> UUID` + `removeZapReceivedCallback(_:)`
  - `onStreamReceived` → `addStreamReceivedCallback(_:) -> UUID` + `removeStreamReceivedCallback(_:)`
- Update all call sites to use `add/remove` pattern
- Each manager stores its callback ID and removes it in `stopListening()`/`deinit`

**Files modified:** `NostrSDKClient.swift`, `StreamActivityManager.swift`, `ChatConnectionManager.swift`, `ZapManager.swift`, `StreamViewModel.swift`, `NostrAuthManager.swift`

---

## Phase 5: Clean Up ContentView Duplication

**Objective:** Remove the duplicated stream-selection closure that constructs `streamWithProfile` identically in two places.

**What changes:**
- In `ContentView.swift`, the stream selection handler (lines 464-490 and 504-530) is copy-pasted for the Curated and Following tabs — 26 identical lines × 2
- Extract into a private method:
  ```swift
  private func selectStream(_ stream: Stream, url: URL, lightningAddress: String?) {
      // shared logic
  }
  ```
- The `Stream` reconstruction with profile attachment (lines 472-486) is also verbose because `Stream` is a struct with 12 fields. Add a `func withProfile(_ profile: Profile?) -> Stream` method on `Stream` to simplify this
- Replace both closures with calls to the shared method

**Files modified:** `ContentView.swift`, `Stream.swift`

---

## Phase 6: Clarify Chat/Zap Manager Responsibilities

**Objective:** Remove redundant managers so there's one clear owner for chat messages and one for zaps.

**What changes:**
- Currently there are **three** components handling kind 1311 chat messages:
  1. `ChatManager.swift` — standalone chat manager (used nowhere in the active code path)
  2. `ChatConnectionManager.swift` — singleton with RAII subscriptions (configured but not actively receiving due to callback overwriting from Phase 4)
  3. `StreamActivityManager.swift` — the one actually in use (receives both chat + zaps)
- After Phase 4 fixes callback routing, decide the canonical path:
  - **Keep `StreamActivityManager`** as the active manager for the video player (it handles both chat + zaps in one subscription, which is efficient)
  - **Keep `ChatConnectionManager`** as infrastructure for future multi-stream chat
  - **Remove `ChatManager.swift`** entirely — it duplicates `StreamActivityManager`'s chat handling and is not referenced in any active view
- Move `ChatMessage` struct from `ChatManager.swift:199-204` to its own location (or into `StreamActivityManager.swift`) before deleting

**Files modified:** `StreamActivityManager.swift`
**Files deleted:** `ChatManager.swift`

---

## Phase 7: Fix Thread-Safety Issues

**Objective:** Ensure all UI-state mutations happen on MainActor and eliminate dispatch queue races.

**What changes:**
- `NostrClient.swift:49-51`: Uses `profileQueue.sync` for reads and `profileQueue.async(flags: .barrier)` for writes. After Phase 3 extracts the cache to an actor, this is resolved. For any remaining dispatch queue usage:
  - `pendingProfileRequests` at line 50 is guarded by `pendingRequestsQueue` — convert to an actor-isolated property or use `@MainActor`
- `NostrClient.swift:387-388`: `self.onStreamReceived?(stream)` dispatches to main thread but captures `self` strongly in the closure. Add `[weak self]` guard
- `NostrClient.swift:491-493`, `516-518`, `661-663`: Same pattern — `DispatchQueue.main.async { self.onXReceived? }` without `[weak self]`
- `NostrAuthManager.swift:11`: Not marked `@MainActor` but publishes `@Published` properties that views observe. Add `@MainActor` annotation
- `LiveChatView.swift:191`: Preview uses `try!` for `NostrSDKClient()` — acceptable in previews but wrap in `#if DEBUG`
- `VideoPlayerView.swift:347`: `Timer.scheduledTimer` captures `[self]` (a struct value). In a SwiftUI struct this captures the current snapshot. The timer closure should use `liveActivityManager` directly rather than capturing `self`

**Files modified:** `NostrClient.swift`, `NostrAuthManager.swift`, `VideoPlayerView.swift`, `LiveChatView.swift`

---

## Phase 8: Reduce NostrClient.swift Size

**Objective:** Make `NostrClient.swift` (1160 lines) easier to navigate by splitting along existing MARK boundaries.

**What changes:**
- This file contains four distinct concerns:
  1. **Data types** (lines 1-42): `NostrEvent`, `NostrProfile`, `ProfileCacheEntry` structs
  2. **Connection management** (lines 43-195): WebSocket lifecycle, relay connections
  3. **Event parsing** (lines 196-738): Seven `handle*Event` methods + helpers
  4. **Event creation & publishing** (lines 963-1160): `createSignedEvent`, `publishEvent`, `publishTextNote`, `publishReaction`, `publishZapRequest`
- Split into:
  - `NostrClient.swift` — connection management + event routing (~200 lines)
  - `NostrClient+EventHandlers.swift` — all `handle*Event` methods as extension (~550 lines)
  - `NostrClient+Publishing.swift` — event creation and publishing as extension (~200 lines)
- `NostrEvent` and `NostrProfile` structs stay in `NostrClient.swift` for now (they'll be removed when Phase 3-4 of the SDK migration completes)

**Files modified:** `NostrClient.swift`
**Files created:** `nostrTV/NostrClient+EventHandlers.swift`, `nostrTV/NostrClient+Publishing.swift`

---

## Phase 9: Simplify Stream.category with Lookup Table

**Objective:** Replace the 8-level if-else chain with a data-driven approach that's easier to maintain.

**What changes:**
- `Stream.swift:30-51` checks tags against 8 hardcoded category lists using nested `contains(where:)` calls
- Replace with a dictionary lookup:
  ```swift
  private static let tagToCategory: [String: String] = [
      "music": "Music", "audio": "Music", "song": "Music", ...
      "gaming": "Gaming", "game": "Gaming", ...
  ]

  var category: String {
      for tag in tags {
          if let cat = Self.tagToCategory[tag.lowercased()] {
              return cat
          }
      }
      return tags.isEmpty ? "General" : "Other"
  }
  ```
- This is O(n) instead of O(n×m) and eliminates the repeated `contains(where:)` calls

**Files modified:** `Stream.swift`

---

## Phase 10: Clean Up Error Types

**Objective:** Remove scattered `NSError` usage and consolidate error handling.

**What changes:**
- `NostrClient.swift:948,952,1072,1076` creates `NSError` with custom domain — replace with `NostrEventError` cases (`.invalidRelayURL`, `.notConnectedToRelay`)
- `NostrEventError` (line 1154) has `.signingFailed` and `.publishFailed` that are never thrown — remove them
- Ensure all error enums conform to `LocalizedError` consistently (some do, some don't):
  - `NostrEventError` — missing `errorDescription`
  - `BunkerError` — already has it
  - `ZapRequestError` — already has it
  - `LiveActivityError` — already has it
  - `NostrAuthError` — already has it

**Files modified:** `NostrClient.swift`

---

## Verification Checklist

After each phase, verify nothing broke:

1. **Build succeeds:**
   ```bash
   xcodebuild -project nostrTV.xcodeproj -scheme nostrTV \
     -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" build
   ```

2. **Tests pass:**
   ```bash
   xcodebuild -project nostrTV.xcodeproj -scheme nostrTV \
     -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" test
   ```

3. **No new warnings:** Compare warning count before and after each phase

4. **Functional smoke test** (manual, after all phases):
   - App launches and shows Curated tab with streams
   - Tapping a stream opens the video player
   - Live chat messages appear in the chat column
   - Zap chyron rotates through zap receipts
   - Profile pictures and names load correctly
   - Streamer profile popup opens when tapping the banner
   - Login flow works (bunker authentication)
   - Following tab shows streams from followed users after login
