# NostrSDK Integration Refactoring

**Branch**: `refactor/nostr-sdk-integration`
**Started**: 2026-01-07
**Status**: IN PROGRESS

## Objective

Replace custom WebSocket and Nostr protocol implementation with official NostrSDK from `tkhumush/nostr-sdk-ios` to reduce code complexity, improve reliability, and leverage battle-tested implementations.

## Benefits

- ✅ Reduce codebase by ~72% (~1420 lines → ~400 lines)
- ✅ Type-safe event handling with compile-time checks
- ✅ Built-in event validation and signing
- ✅ Automatic relay connection management
- ✅ Better Lightning zap support (lud06 + lud16)
- ✅ Unified event stream with Combine publishers
- ✅ Proper NIP compliance with SDK updates

## Phase Overview

### Phase 1: NostrSDKClient Wrapper ✅ COMPLETE
Create new SDK-based client alongside existing NostrClient without breaking changes.

**Files created:**
- ✅ `REFACTORING.md` (this file)
- ✅ `nostrTV/NostrSDKClient.swift` - New relay pool wrapper (652 lines)

**Files not needed:**
- ❌ `nostrTV/NostrSDKModels.swift` - Not needed, using existing models
- 🔲 `nostrTVTests/NostrSDKClientTests.swift` - Deferred to Phase 2

**Status**: ✅ Complete (2026-01-07)

**Implementation Summary:**
- Full RelayPool integration with Combine publishers
- All event handlers implemented:
  - ✅ Kind 0 (Metadata) - with UserMetadata parsing
  - ✅ Kind 3 (Follow List)
  - ✅ Kind 10002 (Relay List)
  - ✅ Kind 1311 (Live Chat)
  - ✅ Kind 9735 (Zap Receipt) - with bolt11 parsing
  - ✅ Kind 24133 (Bunker Message) - with legacy conversion
  - ✅ Kind 30311 (Live Stream) - full metadata extraction
- Profile caching with LRU eviction (matching NostrClient)
- Backward-compatible callback interface
- Build succeeds ✅

---

### Phase 2: ChatManager Migration 🔲 TODO
Refactor ChatManager to use NostrSDKClient and SDK Filter.

**Files to modify:**
- `nostrTV/ChatManager.swift`

**Changes:**
- Replace manual JSON filters with SDK `Filter` objects
- Use SDK subscription management
- Leverage SDK event parsing

**Status**: Not started

---

### Phase 3: Main Client Migration 🔲 TODO
Switch core app to use NostrSDKClient.

**Files to modify:**
- `nostrTV/StreamViewModel.swift`
- `nostrTV/ContentView.swift`
- `nostrTV/VideoPlayerView.swift`
- `nostrTV/LiveActivityManager.swift`

**Changes:**
- Replace NostrClient with NostrSDKClient
- Update profile handling to use MetadataEvent
- Update stream discovery filters
- Update event publishing

**Status**: Not started

---

### Phase 4: Cleanup & Removal 🔲 TODO
Remove old implementation after full migration.

**Files to delete:**
- `nostrTV/NostrClient.swift` (1150 lines removed!)

**Files to modify:**
- Remove custom `NostrEvent` struct (use SDK's)
- Remove custom `NostrProfile` struct (use SDK's UserMetadata)
- Update all imports

**Status**: Not started

---

## Implementation Details

### NostrSDKClient Architecture

```swift
class NostrSDKClient {
    // Core components
    private let relayPool: RelayPool
    private var cancellables: Set<AnyCancellable>

    // Callbacks (matching existing NostrClient interface)
    var onStreamReceived: ((Stream) -> Void)?
    var onProfileReceived: ((Profile) -> Void)?
    var onChatReceived: ((ChatMessage) -> Void)?
    var onZapReceived: ((ZapComment) -> Void)?
    var onBunkerMessageReceived: ((NostrEvent) -> Void)?

    // Methods
    func connect()
    func disconnect()
    func subscribe(with filter: Filter) -> String
    func publishEvent(_ event: NostrEvent)
    func getProfile(for pubkey: String) -> Profile?
}
```

### Key Mappings

| Old | New |
|-----|-----|
| `NostrEvent` (custom struct) | `NostrSDK.NostrEvent` (class) |
| `NostrProfile` (custom) | `UserMetadata` (SDK) |
| Manual `["REQ", id, filter]` | `relayPool.subscribe(with: Filter(...))` |
| Manual `["EVENT", {...}]` | `relayPool.publishEvent(event)` |
| Manual WebSocket dict | `RelayPool` with state tracking |
| Manual JSON parsing | SDK's typed event classes |

### Event Kind Mappings

```swift
// Custom kinds not in SDK enum yet
extension EventKind {
    static let liveStream = EventKind(rawValue: 30311)      // NIP-53
    static let liveChat = EventKind(rawValue: 1311)         // NIP-53
    static let zapReceipt = EventKind(rawValue: 9735)       // NIP-57
    static let zapRequest = EventKind(rawValue: 9734)       // NIP-57
    static let bunkerMessage = EventKind(rawValue: 24133)   // NIP-46
}
```

---

## Progress Tracking

### Completed ✅
- [x] Created refactoring branch
- [x] Created REFACTORING.md documentation
- [x] Analyzed NostrSDK capabilities
- [x] Mapped current implementation to SDK equivalents
- [x] **Phase 1 Complete** - NostrSDKClient.swift (652 lines)
  - [x] Basic RelayPool initialization
  - [x] Event routing to callbacks via Combine
  - [x] Profile caching with LRU eviction
  - [x] Stream event handling (kind 30311)
  - [x] Chat event handling (kind 1311)
  - [x] Zap event handling (kind 9735)
  - [x] Bunker message handling (kind 24133)
  - [x] Follow list (kind 3) and relay list (kind 10002)
  - [x] Build verification

### In Progress ⏳
- [ ] None (ready for Phase 2)

### Next Steps 🔲
1. Complete NostrSDKClient implementation
2. Write unit tests for NostrSDKClient
3. Test alongside existing NostrClient
4. Refactor ChatManager to use NostrSDKClient
5. Test chat functionality thoroughly
6. Switch StreamViewModel to NostrSDKClient
7. Remove old NostrClient.swift

---

## Testing Checklist

Before each phase completion:

- [ ] Build succeeds without errors
- [ ] All existing tests pass
- [ ] New functionality tested manually
- [ ] No regressions in:
  - [ ] Stream discovery
  - [ ] Profile loading
  - [ ] Live chat
  - [ ] Zap display
  - [ ] Bunker authentication

---

## Rollback Plan

If issues arise:
1. Switch back to `main` branch
2. Old implementation remains intact until Phase 4
3. NostrSDKClient can be disabled via feature flag if needed

---

## Notes & Decisions

### 2026-01-07 - Phase 1 Complete

**Decisions Made:**
- **Decision**: Use wrapper pattern instead of direct replacement
  - Allows parallel testing
  - Maintains existing interface for easier migration
  - Reduces risk of breaking changes

- **Decision**: Keep Profile and Stream models unchanged
  - Bridge between SDK's UserMetadata and our Profile
  - Minimal changes to UI layer
  - Can refactor models later if needed

- **Discovery**: SDK doesn't have kind 30311, 1311, 9734, 9735, 24133 in EventKind enum
  - Will use `.unknown(rawValue)` pattern
  - Can submit PR to NostrSDK later to add these

**Implementation Notes:**
- MetadataEvent.userMetadata is optional and must be unwrapped
- Filter parameter order matters: `authors` must come before `kinds`
- SDK Tag type has `name`, `value`, and `otherParameters` properties
- Bunker messages need conversion from SDK NostrEvent to legacy struct
- Profile caching implemented identically to NostrClient for consistency

**Build Status:**
- ✅ Builds successfully on first attempt after fixes
- ✅ No warnings related to NostrSDKClient
- ✅ All event handlers compile and type-check correctly

---

## Questions & Answers

**Q**: Should we update Stream and Profile models to use SDK types directly?
**A**: Not in Phase 1. Keep existing models and bridge in NostrSDKClient wrapper for minimal changes.

**Q**: How to handle profile caching with SDK?
**A**: SDK doesn't provide caching. Implement simple cache in NostrSDKClient similar to current implementation.

**Q**: What about bunker client integration?
**A**: NostrBunkerClient uses NostrClient directly. Will need to add SDK event publishing support.

---

## Commit Strategy

- Small, focused commits at each milestone
- Descriptive commit messages
- Test before each commit
- Can pause and resume at any commit boundary

**Commit naming pattern:**
- `feat(sdk): Add NostrSDKClient wrapper with basic relay pool`
- `feat(sdk): Add stream event handling to NostrSDKClient`
- `feat(sdk): Add profile caching to NostrSDKClient`
- `refactor(chat): Migrate ChatManager to use NostrSDKClient`
- etc.

---

## File Size Tracker

| File | Before | After (Phase 1) | Final Target | Phase 1 Change |
|------|--------|-----------------|--------------|----------------|
| NostrClient.swift | 1154 lines | 1154 (unchanged) | DELETED | 0 |
| NostrSDKClient.swift | 0 | **652 lines** | ~650 lines | +652 |
| ChatManager.swift | 135 lines | 135 (unchanged) | ~80 lines | 0 |
| **Net Change (Phase 1)** | - | - | - | **+652** |
| **Projected Final** | **1289** | **1806** | **~730** | **-559** |

**Phase 1 Note**: New NostrSDKClient adds 652 lines temporarily. In Phase 4, we'll delete NostrClient.swift (-1154 lines) and trim ChatManager (-55 lines), resulting in net reduction of ~559 lines (~43% decrease).

---

## Dependencies

Current NostrSDK version in Package.resolved:
```json
{
  "identity" : "nostr-sdk-ios",
  "location" : "https://github.com/tkhumush/nostr-sdk-ios",
  "state" : {
    "branch" : "fix-bytes-conflict-0.3.0",
    "revision" : "32a5b05120e3356e680369d0ec52e32592953b2e"
  }
}
```

No additional dependencies needed ✅
