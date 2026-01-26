# nostrTV Nostr Implementation

> This document describes the Nostr protocol implementation in nostrTV,
> following the format of official NIPs for consistency.

## Overview

nostrTV is a native Apple TV application that discovers and displays live video streams
from the Nostr protocol. It connects to multiple relays to fetch stream metadata,
user profiles, and real-time chat messages.

## Event Kinds Used

### Kind 0 - User Metadata (NIP-01)

**Purpose**: Display user profiles including name, picture, and Lightning address.

**Usage**:
- Fetch profiles for stream hosts
- Display sender information in chat
- Show Lightning address for zaps

**Required Fields**: None (all optional per NIP-01)

**Content Format**: JSON object with profile metadata
```json
{
  "name": "username",
  "display_name": "Display Name",
  "about": "Bio text",
  "picture": "https://example.com/avatar.jpg",
  "nip05": "user@domain.com",
  "lud16": "user@wallet.com"
}
```

**Extensions**: None

---

### Kind 3 - Contacts (NIP-02)

**Purpose**: Fetch follow lists for feed curation.

**Usage**:
- Admin follow list for Discover feed curation
- User follow list for Following tab

**Required Tags**: None (p-tags are the followed pubkeys)

**Content Format**: Optional JSON object with relay hints (legacy)

**Tag Format**:
```json
["p", "<pubkey-hex>", "<relay-url>", "<petname>"]
```

**Extensions**: None

---

### Kind 1311 - Live Chat Message (NIP-53)

**Purpose**: Real-time chat messages during live streams.

**Usage**:
- Display chat overlay during stream playback
- Show sender name and message content

**Required Tags**:
| Tag | Description | Format |
|-----|-------------|--------|
| `a` | Stream reference | `30311:<pubkey>:<d-tag>` |

**Content Format**: Plain text message

**Example Event**:
```json
{
  "kind": 1311,
  "content": "Hello chat!",
  "tags": [
    ["a", "30311:abc123...def:stream-id"]
  ]
}
```

**Extensions**: None

---

### Kind 9734 - Zap Request (NIP-57)

**Purpose**: Request a Lightning zap to a stream or user.

**Usage**:
- Created when user initiates a zap
- Sent to LNURL callback to generate invoice

**Required Tags**:
| Tag | Description |
|-----|-------------|
| `p` | Recipient pubkey |
| `e` | Event ID (if zapping an event) |
| `a` | Addressable event (if zapping a stream) |
| `amount` | Amount in millisats |
| `relays` | Relay hints for receipt |

**Content Format**: Optional zap comment

**Extensions**: None

---

### Kind 9735 - Zap Receipt (NIP-57)

**Purpose**: Proof of Lightning payment.

**Usage**:
- Display zap chyron during streams
- Show zap amount and sender

**Required Tags**:
| Tag | Description |
|-----|-------------|
| `bolt11` | Lightning invoice |
| `description` | Zap request JSON |
| `p` | Recipient pubkey |

**Content Format**: Empty

**Parsing Notes**:
- `description` tag contains the original kind 9734 zap request as JSON
- `bolt11` invoice is parsed to extract amount (supports m/u/n/p multipliers)

**Extensions**: None

---

### Kind 10002 - Relay List Metadata (NIP-65)

**Purpose**: User's preferred relay configuration.

**Usage**:
- Fetch user's relay preferences after login
- Connect to user's personal relays

**Required Tags**:
| Tag | Description | Format |
|-----|-------------|--------|
| `r` | Relay URL | `wss://relay.example.com` |

**Optional Tag Parameters**:
- `read` - Relay is used for reading
- `write` - Relay is used for writing
- (no parameter) - Relay is used for both

**Example Event**:
```json
{
  "kind": 10002,
  "content": "",
  "tags": [
    ["r", "wss://relay.damus.io", "read"],
    ["r", "wss://relay.primal.net", "write"],
    ["r", "wss://relay.snort.social"]
  ]
}
```

**Extensions**: None

---

### Kind 24133 - Nostr Connect (NIP-46)

**Purpose**: Remote signing communication for bunker authentication.

**Usage**:
- Authenticate users via nsecBunker or similar signers
- Request signatures without exposing private keys

**Required Tags**:
| Tag | Description |
|-----|-------------|
| `p` | Recipient pubkey |

**Content Format**: NIP-44 encrypted JSON-RPC request/response

**Extensions**: None

---

### Kind 30311 - Live Event (NIP-53)

**Purpose**: Live stream metadata and discovery.

**Usage**:
- Discover active live streams
- Display stream title, thumbnail, status
- Construct chat subscription a-tag

**Required Tags**:
| Tag | Description |
|-----|-------------|
| `d` | Unique stream identifier |
| `status` | Stream status: `live`, `ended`, `planned` |

**Optional Tags**:
| Tag | Description |
|-----|-------------|
| `title` | Stream title |
| `summary` | Stream description |
| `image` | Thumbnail URL |
| `streaming` | HLS/DASH stream URL |
| `p` | Host pubkey (if different from event author) |
| `t` | Hashtags/categories |
| `current_participants` | Viewer count |

**Content Format**: Empty or additional description

**Example Event**:
```json
{
  "kind": 30311,
  "content": "",
  "tags": [
    ["d", "my-stream-2024"],
    ["title", "Live Coding Session"],
    ["status", "live"],
    ["streaming", "https://example.com/stream.m3u8"],
    ["image", "https://example.com/thumb.jpg"],
    ["p", "abc123..."],
    ["t", "coding"],
    ["t", "nostr"],
    ["current_participants", "42"]
  ]
}
```

**Important Notes**:
- The `d` tag MUST be present for addressable event identification
- Use `event.pubkey` (not p-tag) when constructing a-tags for chat subscriptions

**Extensions**: None

---

## Tag Usage Summary

| Tag | Indexed | Used In | Purpose |
|-----|---------|---------|---------|
| `a` | Yes | 1311, 9734, 9735 | Addressable event reference |
| `d` | Yes | 30311 | Addressable event identifier |
| `e` | Yes | 9734, 9735 | Event reference |
| `p` | Yes | 0, 3, 9734, 9735, 24133, 30311 | Pubkey reference |
| `r` | Yes | 10002 | Relay URL |
| `t` | Yes | 30311 | Hashtag/category |
| `bolt11` | No | 9735 | Lightning invoice |
| `description` | No | 9735 | Zap request JSON |
| `status` | No | 30311 | Stream status |
| `streaming` | No | 30311 | Stream URL |
| `image` | No | 30311 | Thumbnail URL |
| `title` | No | 30311 | Stream title |
| `summary` | No | 30311 | Stream description |
| `amount` | No | 9734 | Zap amount |
| `current_participants` | No | 30311 | Viewer count |

---

## Security Considerations

### Event Signature Verification

All events SHOULD be verified using NIP-01 Schnorr signature verification before
processing. nostrTV implements signature verification in `NostrEventValidator.swift`.

### Author Filtering for Addressable Events

When querying addressable events (kinds 30000-39999), ALWAYS include the expected
author in the filter to prevent spoofing:

```swift
// SECURE: Filter by author
Filter(authors: [expectedPubkey], kinds: [30311], tags: ["d": [dTag]])

// INSECURE: Anyone could publish with this d-tag
Filter(kinds: [30311], tags: ["d": [dTag]])
```

### Admin Operations

The Discover feed is curated by a trusted admin's follow list. Admin pubkeys are
configured in `AdminConfig` and support multi-admin quorum for sensitive operations.

### Lightning Address Verification

Before displaying zap targets, verify that the Lightning address belongs to the
actual stream owner by checking the profile's `lud16` field.

### NIP-05 Verification

NIP-05 addresses (`nip05` field in profiles) should be verified by fetching
`/.well-known/nostr.json` from the domain and confirming the pubkey matches.

---

## Relay Configuration

### Default Relays

nostrTV connects to the following relays by default:

```
wss://relay.snort.social
wss://relay.tunestr.io
wss://relay.damus.io
wss://relay.primal.net
wss://purplepag.es
```

### User Relay Preferences

After login, the app fetches the user's kind 10002 relay list and prioritizes
their preferred relays for publishing.

### Relay Selection for Different Operations

| Operation | Relays Used |
|-----------|-------------|
| Stream discovery | All default relays |
| Profile fetch | First available relay |
| Chat subscription | All default relays |
| Event publishing | User's write relays (or all) |
| Follow list fetch | All default + user relays |

---

## Connection Resilience

### Heartbeat Monitoring

The client monitors connection health by tracking the last message time. If no
messages are received for 60 seconds, the connection is considered dead.

### Reconnection Strategy

Exponential backoff reconnection with the following parameters:
- Initial delay: 1 second
- Maximum delay: 30 seconds
- Backoff multiplier: 2x
- Reset on successful message receipt

### Subscription Recovery

After reconnection, active subscriptions are automatically recreated to resume
data flow.

---

## Rate Limiting

To prevent overwhelming relays, the client implements rate limiting:
- Maximum 10 requests per second
- Profile requests are batched (up to 30 per request)
- 200ms delay between batch requests

---

## References

- [NIP-01: Basic Protocol](https://github.com/nostr-protocol/nips/blob/master/01.md)
- [NIP-02: Contact List](https://github.com/nostr-protocol/nips/blob/master/02.md)
- [NIP-05: DNS Verification](https://github.com/nostr-protocol/nips/blob/master/05.md)
- [NIP-46: Nostr Connect](https://github.com/nostr-protocol/nips/blob/master/46.md)
- [NIP-53: Live Activities](https://github.com/nostr-protocol/nips/blob/master/53.md)
- [NIP-57: Lightning Zaps](https://github.com/nostr-protocol/nips/blob/master/57.md)
- [NIP-65: Relay List Metadata](https://github.com/nostr-protocol/nips/blob/master/65.md)

---

*Last Updated: 2026-01-21*
*nostrTV Version: 1.0*
