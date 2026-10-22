# Avatar and chat profile investigation — October 21, 2026

Branch: `codex/profile-avatar-resolution`, based on `dev` at `1e8374b`.

## Findings

- Every kind 0 relay response replaced the cached profile without comparing event timestamps. Slow or stale relays could roll back names and pictures; identical copies also invalidated chat repeatedly. A live diagnostic query observed multiple profile versions for the same public key across the configured relays. [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md#kinds) requires keeping the latest replaceable event, with the lowest event ID winning timestamp ties.
- Discover did not subscribe to profile-arrival callbacks. A profile arriving after the stream list settled could remain invisible until another stream update happened to refresh the list.
- A rate-limited profile batch retried through the public deduplication method while its keys were still marked pending. That method discarded the retry. Separately, the first relay's EOSE closed a lookup after two seconds, and missing profiles were suppressed for an hour even when a slower relay could have answered.
- The SDK could discard an entire metadata object because an optional string field had the wrong JSON type. Blank display names did not fall back to the regular name, and legacy `displayName` metadata was ignored. Missing names were rendered as identical Anonymous labels.
- Avatars cleared their displayed image while a picture URL changed and had no retry for a transient initial image failure. Mention-only profile arrivals also did not trigger chat refreshes.

## Changes

- Cache and notify only accepted profile versions. Commit cache changes before callbacks, normalize lookup keys, reject older/duplicate events, and avoid notifications for unchanged data. Cache expiry and LRU updates now happen atomically with reads.
- Notify the existing observed stream list when a host profile arrives, preserving card order. Continue using the shared Nostr client and per-consumer callbacks; cleanup removes the list's callback.
- Reserve deduplicated lookup keys atomically. Retry reserved batches directly after throttling. Profile lookups remain open for a bounded 20-second response window rather than closing on the fastest relay's EOSE. Missing profiles can be requested again after a one-minute backoff when activity or appearance requests them.
- Register subscriptions before sending them, so a relay that connects during the initial send can replay the request. Final testing exposed the previous send-before-register race when both local relays connected at the same moment as a profile lookup.
- Parse metadata fields independently, accept both display-name spellings, trim blank names, and retain useful fields when unrelated values are malformed. Chat uses the resolved name or a shortened public key. Mentioned-person arrivals refresh the existing rows.
- Retain the current avatar during a same-person picture refresh and retry transient HTTP/network failures once. Explicit picture removal and switching people still clear the old avatar. Permanent failures keep the normal placeholder.

## Verification

- Unit tests cover out-of-order/duplicate profiles, timestamp ties, intentional newer edits, tolerant parsing, name fallback, Discover invalidation after late metadata, unchanged-profile notification suppression, late mentions, and transient image retry.
- Local WebSocket relay integration tests cover a saturated rate limiter and an empty fast relay paired with a slower metadata relay. They exercise actual SDK subscriptions and metadata delivery without relying on public relay timing.
- The existing native navigation, artwork, and split-track HLS/LL-HLS loader tests are included in final validation.
- Debug and unsigned Release builds pass. All 64 tests pass on the tvOS 18.5 simulator, including the HLS playlist-loader integration tests and signing in after discovery has already cached the account profile.

## Release preparation

- Shared buttons have a 36-point minimum content height so short symbols, including the player's ellipsis, match the chat, zap and cinema controls.
- Toggling chat restores focus to its button after the player width changes, so the next Select toggles it back instead of activating another control.
- The minimum supported tvOS version is consistently 18.5 for the project, app and test targets, as requested for this release.

Profile availability is still dependent on publishers and reachable relays. A genuinely absent profile or broken image URL cannot be turned into a name or photo; the fallback remains visible and distinguishes chat authors by public key.
