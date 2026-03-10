# Livestream Filtering Rewrite (iOS) — Matching zap.stream's Approach

## Goal

Rewrite nostrTV iOS's livestream filtering pipeline to match the battle-tested approach used by **zap.stream** ([github.com/v0l/zap.stream](https://github.com/v0l/zap.stream)). The new filtering must apply uniformly to **both** the Discover (admin) and Following (user) tabs — treating the admin follow list and user follow list as two equivalent feed sources that both benefit from the same clean filtering pipeline.

## Context: What zap.stream Does

zap.stream's filtering lives in two hooks:
- `src/hooks/live-streams.ts` — relay subscription
- `src/hooks/useLiveStreams.ts` — client-side filtering pipeline (`useSortedStreams`)

Their pipeline, in order:

```
Raw relay events (kind 30311, open subscription)
  → Age filter: discard events older than 7 days (we'll use 24 hours)
  → Playability filter: must have valid .m3u8 or moq: streaming URL
  → Host whitelist filter (we skip this — we use admin curation instead)
  → Status bucketing:
      - "live" → live list (sorted by `starts` tag)
      - "planned" → planned list (sorted by `starts` tag)
      - "ended" + has recording URL → ended list (sorted by created_at)
      - "ended" without recording → DROPPED
  → Muted hosts: filter out streams from user's mute list
  → Deletion events: subscribe to kind 5 events referencing live streams
```

## Current iOS Code to Modify

### Files to change:

1. **`nostrTV/Stream.swift`**
   - `Stream` struct (line 10) — data model, needs new fields

2. **`nostrTV/NostrSDKClient.swift`**
   - `subscribeToStreams()` (line 411) — relay subscription filter
   - `handleLiveStreamEvent()` (line 864) — event parsing, no filtering applied here currently

3. **`nostrTV/StreamViewModel.swift`**
   - `setupCallbacks()` → `onStreamReceived` (line 99) — current filtering: `isLive` check only
   - `evictOldStreamsIfNeeded()` (line 304) — memory-based eviction
   - `updateCategorizedStreams()` (line 357) — Discover/Following split
   - `validateStreamURL()` (line 434) — async AVAsset playability check (15s timeout)

4. **`nostrTV/ContentView.swift`**
   - Stream display logic — uses `isLive` for visual treatment

### Current Filtering Pipeline (what exists today)

```
Raw relay events (kind 30311, limit 50, no other relay-side filters)
  → Status filter: stream.isLive (status == "live") — all others dropped (line 110)
  → Pubkey check: must have pubkey — drops orphan events (line 115)
  → Dedup: one stream per pubkey, keep newest by createdAt (line 121)
  → Memory cap: evict if > 200 streams (line 142/304)
  → Async URL validation: AVAsset.load(.isPlayable) with 15s timeout (line 434)
  → Tab split: admin follow list → Discover, user follow list → Following (line 357)
```

**What's missing vs. zap.stream:**
- ❌ Age-based filtering (no time cutoff at all)
- ❌ URL format check (relies entirely on expensive AVAsset probe)
- ❌ `starts` tag extraction/sorting
- ❌ `recording` tag extraction
- ❌ `planned` status handling
- ❌ `ended` + recording display (all ended streams are dropped)
- ❌ Deletion event (kind 5) handling
- ❌ NIP-33 dedup by `pubkey:d-tag` (currently dedupes by pubkey only — one stream per streamer)

## Implementation Plan

### Step 1: Update Stream model with new fields

In `nostrTV/Stream.swift`:

```swift
struct Stream: Identifiable, Codable, Equatable {
    let streamID: String          // The "d" tag identifier
    let eventID: String?          // The actual Nostr event ID
    let title: String
    let streaming_url: String
    let imageURL: String?
    let pubkey: String?           // Host pubkey (from p-tag)
    let eventAuthorPubkey: String? // Event author pubkey (event signer)
    let profile: Profile?
    let status: String
    let tags: [String]
    let createdAt: Date?
    let viewerCount: Int
    let recording: String         // ADD: recording URL from "recording" tag
    let startsAt: Date?           // ADD: scheduled start from "starts" tag

    var id: String { streamID }

    /// The Nostr "a-tag" coordinate: 30311:<eventAuthorPubkey>:<d-tag>
    var aTag: String? {           // ADD: for deletion event matching
        guard let authorPubkey = eventAuthorPubkey else { return nil }
        return "30311:\(authorPubkey):\(streamID)"
    }

    var isLive: Bool {
        return status == "live"
    }

    // ... category stays the same ...
}
```

### Step 2: Fix `handleLiveStreamEvent()` in NostrSDKClient.swift

Update the parser (line 864) to extract `recording` and `starts` tags:

```swift
private func handleLiveStreamEvent(_ event: NostrSDK.NostrEvent) {

    func tagValue(_ name: String) -> String? {
        event.tags.first { $0.name == name }?.value
    }

    // ... existing title, summary, streamURL, streamID, status, imageURL extraction ...

    // ADD: Extract recording URL and starts time
    let recording = tagValue("recording") ?? ""
    let startsAt: Date? = {
        if let startsString = tagValue("starts"),
           let startsTimestamp = TimeInterval(startsString) {
            return Date(timeIntervalSince1970: startsTimestamp)
        }
        return nil
    }()

    // ... existing pubkey, viewerCount, tags, createdAt extraction ...

    let stream = Stream(
        streamID: streamID,
        eventID: event.id,
        title: combinedTitle,
        streaming_url: finalStreamURL,
        imageURL: imageURL,
        pubkey: hostPubkey,
        eventAuthorPubkey: eventAuthorPubkey,
        profile: nil,
        status: status,
        tags: allTags,
        createdAt: createdAt,
        viewerCount: viewerCount,
        recording: recording,      // ADD
        startsAt: startsAt         // ADD
    )

    // ... rest stays the same ...
}
```

### Step 3: Add filtering utilities in StreamViewModel.swift

Add static/private helper methods matching zap.stream's `canPlayUrl` + `canPlayEvent`:

```swift
// MARK: - zap.stream Filtering Utilities

/// Maximum age for stream events (24 hours — more aggressive than zap.stream's 7 days)
private static let maxStreamAgeSeconds: TimeInterval = 24 * 60 * 60  // 24 hours

/// Check if a URL is a playable stream URL.
/// Matches zap.stream's canPlayUrl(): must be .m3u8 or moq: protocol.
private static func canPlayUrl(_ urlString: String) -> Bool {
    guard !urlString.isEmpty else { return false }
    // Block localhost URLs
    if urlString.contains("localhost") || urlString.contains("127.0.0.1") { return false }
    guard let url = URL(string: urlString) else { return false }
    return url.path.contains(".m3u8") || url.scheme == "moq"
}

/// Check if a stream has a playable URL (streaming or recording).
/// Matches zap.stream's canPlayEvent().
private static func canPlayStream(_ stream: Stream) -> Bool {
    return canPlayUrl(stream.streaming_url) || canPlayUrl(stream.recording)
}

/// Check if a stream event is within the acceptable age window (24h).
private static func isWithinAgeWindow(_ stream: Stream) -> Bool {
    guard let createdAt = stream.createdAt else { return false }
    return Date().timeIntervalSince(createdAt) < maxStreamAgeSeconds
}
```

### Step 4: Rewrite the filtering pipeline in StreamViewModel.swift

Replace the current `onStreamReceived` callback in `setupCallbacks()` (lines 99-146) and `updateCategorizedStreams()` (lines 357-385).

The key change: **apply the full zap.stream filtering pipeline BEFORE splitting into Discover/Following.** Both tabs get the same clean base list.

```swift
nostrSDKClient.onStreamReceived = { [weak self] stream in
    DispatchQueue.main.async {
        guard let self = self else { return }

        if self.isInitialLoad {
            self.isInitialLoad = false
        }

        // === ZAP.STREAM FILTERING PIPELINE (per-event, on arrival) ===

        // Step 1: Age filter — discard events older than 24 hours
        guard Self.isWithinAgeWindow(stream) else {
            print("⏭️ Skipping old stream: \(stream.streamID) (age > 24h)")
            return
        }

        // Step 2: Playability filter — must have valid .m3u8 streaming URL
        guard Self.canPlayStream(stream) else {
            print("⏭️ Skipping unplayable stream: \(stream.streamID)")
            return
        }

        // Step 3: Require pubkey for profile display
        guard let pubkey = stream.pubkey else {
            print("⚠️ Stream has no pubkey, skipping: \(stream.streamID)")
            return
        }

        // Step 4: Check if this stream has been deleted (kind 5)
        if let aTag = stream.aTag, self.deletedStreamAddresses.contains(aTag) {
            print("⏭️ Skipping deleted stream: \(stream.streamID)")
            return
        }

        // Step 5: NIP-33 dedup by eventAuthorPubkey + d-tag (not just pubkey)
        let dedupKey = "\(stream.eventAuthorPubkey ?? pubkey):\(stream.streamID)"
        if let existingIndex = self.streams.firstIndex(where: {
            "\($0.eventAuthorPubkey ?? $0.pubkey ?? ""):\($0.streamID)" == dedupKey
        }) {
            let existingStream = self.streams[existingIndex]
            let newDate = stream.createdAt ?? Date.distantPast
            let existingDate = existingStream.createdAt ?? Date.distantPast

            if newDate > existingDate {
                self.streams.remove(at: existingIndex)
                self.streams.append(stream)
                self.validateStreamURL(stream)
            }
        } else {
            self.streams.append(stream)
            self.validateStreamURL(stream)
        }

        self.evictOldStreamsIfNeeded()
        self.updateCategorizedStreams()
    }
}
```

The `updateCategorizedStreams()` function stays the same — it already correctly applies admin follow list and user follow list filters on top of `streams`. Both Discover and Following now receive pre-cleaned streams.

Update `categorizeStreams()` to use `startsAt` for sorting when available, and to handle `ended` streams with recordings:

```swift
private func categorizeStreams(_ streamList: [Stream]) -> [StreamCategory] {
    var liveStreamsByCategory: [String: [Stream]] = [:]
    var endedStreams: [Stream] = []

    for stream in streamList {
        if stream.isLive {
            liveStreamsByCategory[stream.category, default: []].append(stream)
        } else if stream.status == "ended" && !stream.recording.isEmpty {
            // Only show ended streams that have a recording (matches zap.stream)
            endedStreams.append(stream)
        }
        // "ended" without recording → DROPPED (matches zap.stream)
        // "planned" → could be added as a future category
    }

    var categories: [StreamCategory] = []

    for categoryName in liveStreamsByCategory.keys.sorted() {
        guard let categoryStreams = liveStreamsByCategory[categoryName] else { continue }

        // Sort by startsAt (like zap.stream), fall back to createdAt
        let sortedStreams = categoryStreams.sorted { s1, s2 in
            let date1 = s1.startsAt ?? s1.createdAt ?? Date.distantPast
            let date2 = s2.startsAt ?? s2.createdAt ?? Date.distantPast
            return date1 > date2
        }
        categories.append(StreamCategory(name: categoryName, streams: sortedStreams))
    }

    if !endedStreams.isEmpty {
        let sortedEnded = endedStreams.sorted { s1, s2 in
            (s1.createdAt ?? Date.distantPast) > (s2.createdAt ?? Date.distantPast)
        }
        categories.append(StreamCategory(name: "Past Streams", streams: sortedEnded))
    }

    return categories
}
```

### Step 5: Subscribe to deletion events (kind 5)

In `NostrSDKClient.swift`, add a subscription method for kind 5 deletion events:

```swift
/// Subscribe to deletion events (kind 5) that reference live stream events.
/// Matches zap.stream's deletion event handling.
/// - Returns: Subscription ID for later closing, or nil if filter creation failed
func subscribeToDeletions() -> String? {
    guard let filter = Filter(kinds: [5], tags: ["k": ["30311"]], limit: 100) else {
        print("❌ NostrSDKClient: Failed to create deletions filter")
        return nil
    }
    let subId = subscribe(with: filter, purpose: "stream-deletions")
    print("✅ NostrSDKClient: Subscribed to stream deletion events: \(subId.prefix(8))...")
    return subId
}
```

Add a callback and handler in `NostrSDKClient`:

```swift
/// Called when a stream deletion event (kind 5) is received
var onStreamDeletion: ((_ deletedATags: Set<String>) -> Void)?
```

In the event routing (where kind 30311, 0, 1311, 9735 are dispatched):

```swift
case 5:
    handleDeletionEvent(event)
```

```swift
/// Handle kind 5 (deletion) events targeting live streams
private func handleDeletionEvent(_ event: NostrSDK.NostrEvent) {
    // Look for "a" tags referencing live streams: 30311:<pubkey>:<d-tag>
    let deletedAddresses = event.tags
        .filter { $0.name == "a" }
        .compactMap { $0.value }
        .filter { $0.hasPrefix("30311:") && $0.contains(event.pubkey) }

    guard !deletedAddresses.isEmpty else { return }

    let deletedSet = Set(deletedAddresses)
    print("🗑️ Stream deletion from \(event.pubkey.prefix(16)): \(deletedSet)")

    DispatchQueue.main.async { [weak self] in
        self?.onStreamDeletion?(deletedSet)
    }
}
```

### Step 6: Wire up deletion handling in StreamViewModel.swift

Add deletion state and callback:

```swift
/// Tracks a-tags of streams that have been explicitly deleted (kind 5)
private var deletedStreamAddresses: Set<String> = []

/// Subscription ID for deletion events
private var deletionsSubscriptionId: String?
```

In `setupCallbacks()`, add:

```swift
// Handle stream deletion events (kind 5)
nostrSDKClient.onStreamDeletion = { [weak self] deletedATags in
    DispatchQueue.main.async {
        guard let self = self else { return }

        self.deletedStreamAddresses.formUnion(deletedATags)

        // Remove deleted streams from active collection
        self.streams.removeAll { stream in
            guard let aTag = stream.aTag else { return false }
            return deletedATags.contains(aTag)
        }

        self.updateCategorizedStreams()
        print("🗑️ Removed \(deletedATags.count) deleted streams")
    }
}
```

In `startSubscriptions()`, after `createStreamsSubscription()`:

```swift
// Subscribe to stream deletion events (kind 5)
self.deletionsSubscriptionId = self.nostrSDKClient.subscribeToDeletions()
```

In `deinit`, close the subscription:

```swift
if let subId = deletionsSubscriptionId {
    nostrSDKClient.closeSubscription(subId)
}
```

## Summary of Changes

| What | Where | Change |
|------|-------|--------|
| `Stream.recording` field | `Stream.swift` | Add field |
| `Stream.startsAt` field | `Stream.swift` | Add field |
| `Stream.aTag` computed property | `Stream.swift` | Add for deletion matching |
| `recording` + `starts` tag parsing | `NostrSDKClient.swift` handleLiveStreamEvent (line 864) | Parse new tags |
| `canPlayUrl()` | `StreamViewModel.swift` | New static function |
| `canPlayStream()` | `StreamViewModel.swift` | New static function |
| `isWithinAgeWindow()` | `StreamViewModel.swift` | New static function |
| Age + playability filtering | `StreamViewModel.swift` onStreamReceived (line 99) | Add pre-dedup filters |
| NIP-33 dedup by `pubkey:d-tag` | `StreamViewModel.swift` onStreamReceived (line 121) | Fix dedup key |
| Sort by `startsAt` tag | `StreamViewModel.swift` categorizeStreams (line 387) | Change sort order |
| Ended stream with recording display | `StreamViewModel.swift` categorizeStreams (line 387) | Filter ended without recording |
| Deletion event subscription | `NostrSDKClient.swift` | New `subscribeToDeletions()` |
| Deletion event handler | `NostrSDKClient.swift` | New `handleDeletionEvent()` |
| Deletion state tracking | `StreamViewModel.swift` | `deletedStreamAddresses` set |
| Deletion callback wiring | `StreamViewModel.swift` setupCallbacks | Remove deleted streams |
| `onStreamDeletion` callback | `NostrSDKClient.swift` | New callback property |
| Kind 5 event routing | `NostrSDKClient.swift` event handler | Route to deletion handler |

## Key Differences: iOS vs Android Implementation

| Aspect | Android | iOS |
|--------|---------|-----|
| Nostr client | Custom `NostrClient.kt` | `NostrSDKClient` wrapping NostrSDK `RelayPool` |
| Stream model | `LiveStream` data class | `Stream` struct (Codable, Identifiable) |
| Filtering location | `HomeViewModel.connectAndSubscribe()` `.collect {}` | `StreamViewModel.setupCallbacks()` `onStreamReceived` |
| Dedup strategy | Flow-based batch `distinctBy` | Per-event callback with array mutation |
| URL validation | Sync `canPlayUrl()` check | Sync `canPlayUrl()` + async `AVAsset.load(.isPlayable)` |
| Tab split | `updateFilteredStreams()` | `updateCategorizedStreams()` |
| Stream state | `StreamState` enum | `status: String` (+ `isLive` computed property) |
| Stream identity | `"${pubkey}:${dTag}"` | `streamID` (d-tag only, currently); should be `eventAuthorPubkey:streamID` |

## What We're NOT Doing (and why)

- **No env-var whitelist** — We already have admin curation via follow lists
- **No muted hosts** — Not yet implemented; can be added later with a mute list feature
- **No dead link HTTP HEAD probes** — We already have the better approach: `AVAsset.load(.isPlayable)` which actually tests playback, not just HTTP status. The new `canPlayUrl()` check is a fast pre-filter to avoid expensive AVAsset probes on obviously bad URLs
- **No N94 (kind 1053) support** — Not widely adopted yet
- **No `StreamState` enum** — The iOS app uses `status: String` with computed `isLive`. Adding an enum would require changes across ContentView and would be a larger refactor. The string comparison approach works fine and matches how the data arrives from relays

## Testing Checklist

After implementing:

1. ✅ Verify stale "ghost" streams (events older than 24h with status=live but streamer is offline) no longer appear
2. ✅ Verify streams without `.m3u8` URLs are filtered out before expensive AVAsset validation
3. ✅ Verify both Discover and Following tabs show only clean, playable live streams
4. ✅ Verify ended streams without recordings don't appear anywhere
5. ✅ Verify stream ordering uses `startsAt` tag when available
6. ✅ Verify deleted streams (kind 5) are removed
7. ✅ Test with relay that has many old events (nostr.wine) to confirm age filter works
8. ✅ Verify no regressions in chat, zaps, or presence features
9. ✅ Verify NIP-33 dedup allows multiple streams from same pubkey (different d-tags)
10. ✅ Verify AVAsset validation still runs as a secondary check after the fast `canPlayUrl()` pre-filter
