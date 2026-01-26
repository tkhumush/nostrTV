# Nostr Protocol AI Agent Instructions

This document provides AI agents with comprehensive guidance for building applications on the Nostr protocol. It covers protocol fundamentals, implementation patterns, security considerations, and best practices.

## Nostr Protocol Overview

Nostr (Notes and Other Stuff Transmitted by Relays) is a decentralized protocol for social networking and communication. Key concepts:

- **Events**: The fundamental data unit in Nostr, containing content, tags, signatures, and metadata
- **Relays**: Servers that store and forward events between clients
- **Public/Private Keys**: Users are identified by cryptographic key pairs (no usernames or passwords)
- **NIPs**: Nostr Implementation Possibilities - the protocol specification documents

## Nostr Implementation Guidelines

### Before Implementing Any Feature

1. Always check the full list of existing NIPs before implementing any Nostr features
2. Review what event kinds are currently in use across all NIPs
3. If any existing kind or NIP might offer the required functionality, read the relevant NIPs thoroughly
4. Several NIPs may need to be read before making a decision
5. Only generate new kind numbers if no existing suitable kinds are found after comprehensive research

### Choosing Between Existing NIPs and Custom Kinds

When implementing features that could use existing NIPs, follow this decision framework:

1. **Thorough NIP Review**: Before considering a new kind, perform a comprehensive review of existing NIPs and their associated kinds. Get an overview of all NIPs, then read specific NIPs and kind documentation in detail.

2. **Prioritize Existing NIPs**: Always prefer extending or using existing NIPs over creating custom kinds, even if they require minor compromises in functionality.

3. **Interoperability vs. Perfect Fit**: Consider the trade-off between:
   - **Interoperability**: Using existing kinds means compatibility with other Nostr clients
   - **Perfect Schema**: Custom kinds allow perfect data modeling but create ecosystem fragmentation

4. **Extension Strategy**: When existing NIPs are close but not perfect:
   - Use the existing kind as the base
   - Add domain-specific tags for additional metadata
   - Document the extensions clearly

5. **When to Generate Custom Kinds**:
   - No existing NIP covers the core functionality
   - The data structure is fundamentally different from existing patterns
   - The use case requires different storage characteristics (regular vs replaceable vs addressable)
   - If a tool is available to generate a kind, always use it rather than picking an arbitrary number

6. **Custom Kind Publishing**: When publishing events with custom generated kinds, always include a NIP-31 "alt" tag with a human-readable description of the event's purpose.

**Example Decision Process**:
```
Need: Equipment marketplace for farmers
Options:
1. NIP-15 (Marketplace) - Too structured for peer-to-peer sales
2. NIP-99 (Classified Listings) - Good fit, can extend with farming tags
3. Custom kind - Perfect fit but no interoperability

Decision: Use NIP-99 + farming-specific tags for best balance
```

## Event Kind Ranges

An event's kind number determines the event's behavior and storage characteristics:

- **Regular Events** (1000 ≤ kind < 10000): Expected to be stored by relays permanently. Used for persistent content like notes, articles, etc.

- **Replaceable Events** (10000 ≤ kind < 20000): Only the latest event per pubkey+kind combination is stored. Used for profile metadata, contact lists, etc.

- **Addressable Events** (30000 ≤ kind < 40000): Identified by pubkey+kind+d-tag combination, only latest per combination is stored. Used for articles, long-form content, marketplace listings, etc.

Kinds below 1000 are considered "legacy" kinds and may have different storage characteristics based on their kind definition. For example, kind 1 is regular, while kind 3 is replaceable.

## Tag Design Principles

When designing tags for Nostr events, follow these principles:

### Kind vs Tags Separation

- **Kind** = Schema/structure (how the data is organized)
- **Tags** = Semantics/categories (what the data represents)
- Don't create different kinds for the same data structure

### Use Single-Letter Tags for Categories

- **Relays only index single-letter tags** for efficient querying
- Use `t` tags for categorization, not custom multi-letter tags
- Multiple `t` tags allow items to belong to multiple categories

### Tag Examples

```json
// ❌ Wrong: Multi-letter tag, not queryable at relay level
["product_type", "electronics"]

// ✅ Correct: Single-letter tag, relay-indexed and queryable
["t", "electronics"]
["t", "smartphone"]
["t", "android"]
```

### Querying Best Practices

```
// ❌ Inefficient: Get all events, filter client-side
Query all events of kind, then filter by custom tag in application code

// ✅ Efficient: Filter at relay level
Query with filter: { kinds: [30402], '#t': ['electronics'] }
```

### `t` Tag Filtering for Community-Specific Content

For applications focused on a specific community or niche, use `t` tags to filter events for the target audience.

**When to Use:**
- ✅ Community apps: "farmers" → `t: "farming"`, "Poland" → `t: "poland"`
- ❌ Generic platforms: Twitter clones, general Nostr clients

## Content Field Design Principles

When designing new event kinds, the `content` field should be used for semantically important data that doesn't need to be queried by relays. **Structured JSON data generally shouldn't go in the content field** (kind 0 being an early exception).

### Guidelines

- **Use content for**: Large text, freeform human-readable content, or existing industry-standard JSON formats (Tiled maps, FHIR, GeoJSON)
- **Use tags for**: Queryable metadata, structured data, anything that needs relay-level filtering
- **Empty content is valid**: Many events need only tags with `content: ""`
- **Relays only index tags**: If you need to filter by a field, it must be a tag

### Example

**✅ Good - queryable data in tags:**
```json
{
  "kind": 30402,
  "content": "",
  "tags": [["d", "product-123"], ["title", "Camera"], ["price", "250"], ["t", "photography"]]
}
```

**❌ Bad - structured data in content:**
```json
{
  "kind": 30402,
  "content": "{\"title\":\"Camera\",\"price\":250,\"category\":\"photo\"}",
  "tags": [["d", "product-123"]]
}
```

## NIP Documentation

Projects using custom Nostr kinds should maintain a `NIP.md` file to define custom protocol extensions. This file should:

- Document all custom event kinds used by the project
- Describe the schema and required/optional tags for each kind
- Be updated whenever the schema of custom events changes
- Follow the format of official NIPs for consistency

## Nostr Security Model

**CRITICAL**: Nostr is permissionless - **anyone can publish any event**. When implementing admin/moderation systems or any feature that should only trust specific users, you MUST filter queries by the `authors` field.

Without author filtering, anyone can publish events claiming to be admin actions, moderator decisions, or trusted content.

### Using the `authors` Filter

**Always filter by authors when querying:**
- **Admin/moderator actions** - MUST filter by trusted admin pubkeys
- **Addressable events (kinds 30000-39999)** - MUST include author to prevent anyone from publishing events with the same d-tag
- **Any privileged operations** - Filter by trusted pubkeys only

**✅ Secure - Filtering by trusted authors:**
```
Query organizer appointments - ONLY accept events from admins
Filter: {
  kinds: [30078],
  authors: ADMIN_PUBKEYS,  // CRITICAL: Only trust admin authors
  '#d': ['app-organizers'],
  limit: 1
}
```

**❌ INSECURE - No author filtering:**
```
DANGER: This accepts events from ANYONE who publishes kind 30078
An attacker could appoint themselves as an organizer
Filter: {
  kinds: [30078],
  '#d': ['app-organizers'],
  limit: 1
}
```

### Addressable Events Security

For addressable events, ALWAYS include the author in your filter. This prevents attackers from publishing events with the same d-tag:

```
Filter: {
  kinds: [30023],  // Long-form article
  authors: [authorPubkey],  // CRITICAL: Verify the author
  '#d': ['my-article-slug'],
  limit: 1
}
```

### URL Routing for Addressable/Replaceable Events

When creating URL paths for addressable or replaceable events, always include the author in the URL structure:

```
❌ INSECURE: Missing author - anyone could publish an event with this d-tag
/article/:slug

✅ SECURE: Includes author - can safely filter by both author and d-tag
/article/:npub/:slug
```

### NIP-72 Community Moderation Example

When implementing moderated communities (NIP-72):

1. Query the community definition to get the moderator list (filter by community owner)
2. Extract moderator pubkeys from p tags
3. Query approval events - ONLY from trusted moderators

Without filtering approvals by the moderator list, anyone could publish kind 4550 events claiming to approve posts for the community.

### When Author Filtering Is NOT Required

Author filtering is not needed for public user-generated content where anyone should be able to post (kind 1 notes, reactions, discovery queries, public feeds, etc.).

## NIP-19: Nostr Addresses

Nostr defines a set of bech32-encoded identifiers in NIP-19. Their prefixes and purposes:

- `npub1`: **public keys** - Just the 32-byte public key, no additional metadata
- `nsec1`: **private keys** - Secret keys (should never be displayed publicly)
- `note1`: **event IDs** - Just the 32-byte event ID, specifically for kind:1 events
- `nevent1`: **event pointers** - Event ID plus optional relay hints and author pubkey
- `nprofile1`: **profile pointers** - Public key plus optional relay hints and petname
- `naddr1`: **addressable event coordinates** - For parameterized replaceable events (kind 30000-39999)
- `nrelay1`: **relay references** - Relay URLs (deprecated)

### Key Differences Between Similar Identifiers

**`note1` vs `nevent1`:**
- `note1`: Contains only the event ID (32 bytes) - specifically for kind:1 events (Short Text Notes)
- `nevent1`: Contains event ID plus optional relay hints and author pubkey - for any event kind
- Use `note1` for simple references to text notes and threads
- Use `nevent1` when you need relay hints or author context for any event type

**`npub1` vs `nprofile1`:**
- `npub1`: Contains only the public key (32 bytes)
- `nprofile1`: Contains public key plus optional relay hints and petname
- Use `npub1` for simple user references
- Use `nprofile1` when you need relay hints or display name context

### Use in Filters

The base Nostr protocol uses hex string identifiers when filtering by event IDs and pubkeys. **Nostr filters only accept hex strings.**

```
❌ Wrong: NIP-19 identifier not decoded
Filter: { ids: [naddr] }

✅ Correct: Decode NIP-19, expand into proper filter
Decoded naddr contains: kind, pubkey, identifier
Filter: {
  kinds: [naddr.kind],
  authors: [naddr.pubkey],
  '#d': [naddr.identifier]
}
```

### Implementation Guidelines for NIP-19

1. **Always decode NIP-19 identifiers** before using them in queries
2. **Use the appropriate identifier type** based on your needs
3. **Handle different identifier types** appropriately in routing
4. **Security considerations**: Always use `naddr1` for addressable events as it contains the author pubkey needed for secure filters
5. **Error handling**: Gracefully handle invalid or unsupported NIP-19 identifiers

## Nostr Encryption and Decryption

### NIP-44: Encrypted Direct Messages

NIP-44 is the modern encryption standard for Nostr. Key points:

- Uses conversation keys derived from the sender and recipient's key pairs
- The signer interface handles all cryptographic operations internally
- Never request private keys from users - always use the signer interface
- Signers (browser extensions, apps) expose `nip44.encrypt()` and `nip44.decrypt()` methods

### NIP-04: Legacy Encryption

NIP-04 is the older encryption standard, still supported for backwards compatibility:
- Less secure than NIP-44
- Should be supported for reading old messages
- Prefer NIP-44 for new implementations

## File Uploads on Nostr

### Blossom Servers

Blossom is a file storage protocol for Nostr that:
- Stores files and returns URLs
- Returns NIP-94 compatible tags for file metadata
- Allows files to be attached to events

### NIP-94: File Metadata

When attaching files to events:
- For kind 1 events: Append file URLs to content, add `imeta` tags for each file
- For kind 0 (profile): Use URLs directly in relevant JSON fields
- Include file metadata (dimensions, mime type, hash) in tags

## Efficient Query Design

**Critical**: Always minimize the number of separate queries to avoid rate limiting and improve performance. Combine related queries whenever possible.

### Query Optimization Guidelines

1. **Combine kinds**: Use `kinds: [1, 6, 16]` instead of separate queries
2. **Use multiple filters**: When you need different tag filters, use multiple filter objects in a single query
3. **Adjust limits**: When combining queries, increase the limit appropriately
4. **Filter in application code**: Separate event types after receiving results rather than making multiple requests
5. **Consider relay capacity**: Each query consumes relay resources and may count against rate limits

**✅ Efficient - Single query with multiple kinds:**
```
Query multiple event types in one request
Filter: {
  kinds: [1, 6, 16],  // All repost kinds in one query
  '#e': [eventId],
  limit: 150
}
Then separate by type in application code
```

**❌ Inefficient - Multiple separate queries:**
```
Three separate queries for the same data - creates unnecessary load
Query 1: { kinds: [1], '#e': [eventId] }
Query 2: { kinds: [6], '#e': [eventId] }
Query 3: { kinds: [16], '#e': [eventId] }
```

## Event Validation

When querying events, if the event kind being returned has required tags or required JSON fields in the content, the events should be filtered through a validator function.

- Not generally needed for kinds like 1, where all tags are optional and content is freeform text
- Especially useful for custom kinds and kinds with strict requirements
- Validate required tags exist and have proper format
- Validate content structure for kinds that use JSON content

## Connecting to Multiple Relays

Applications should support:

- **Default pool**: General queries using configured relays with sensible defaults (read from 1, publish to all)
- **Single relay connection**: For specific relay behavior, testing, or debugging
- **Relay groups**: For querying trusted relay sets or geographic optimization

## Common NIPs Reference

Key NIPs to be familiar with:

- **NIP-01**: Basic protocol flow - events, filters, subscriptions
- **NIP-02**: Contact lists (kind 3)
- **NIP-04**: Legacy encrypted direct messages
- **NIP-05**: Nostr address verification (user@domain.com)
- **NIP-07**: Browser extension signer interface
- **NIP-10**: Text notes and threads (kind 1)
- **NIP-19**: Bech32-encoded entities (npub, note, nevent, nprofile, naddr)
- **NIP-23**: Long-form content (kind 30023)
- **NIP-31**: Alt tag for unknown event kinds
- **NIP-44**: Modern encrypted direct messages
- **NIP-46**: Nostr Connect (remote signing)
- **NIP-53**: Live activities/streams
- **NIP-57**: Lightning zaps
- **NIP-65**: Relay list metadata
- **NIP-72**: Moderated communities
- **NIP-94**: File metadata
- **NIP-99**: Classified listings

## Relay Management (NIP-65)

NIP-65 defines how users publish their preferred relay lists:

- Kind 10002 events contain relay URLs with read/write permissions
- Applications should respect user relay preferences
- Sync relay configuration when users log in
- Provide relay management interfaces for users

## Lightning Payments (Zaps - NIP-57)

NIP-57 defines the zap protocol for Lightning payments:

- Users can send sats to other users or events
- Requires Lightning address (lud06 or lud16) in profile
- Zap receipts are published as kind 9735 events
- Integrates with WebLN and Nostr Wallet Connect (NWC)

## Best Practices Summary

1. **Research NIPs thoroughly** before implementing any feature
2. **Prefer existing kinds** over custom kinds for interoperability
3. **Use single-letter tags** for relay-indexed queries
4. **Always filter by authors** for privileged operations
5. **Include authors in URLs** for addressable events
6. **Decode NIP-19 identifiers** before using in filters
7. **Use modern encryption (NIP-44)** for new implementations
8. **Minimize queries** by combining filters
9. **Validate events** with strict schemas
10. **Document custom kinds** in NIP.md files
