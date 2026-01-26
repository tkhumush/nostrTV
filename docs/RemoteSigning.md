# NIP-46 Remote Signing (Nostr Connect) Implementation Guide

This document describes the complete flow for implementing NIP-46 remote signing in a TV application. The implementation uses a **reverse flow** where the TV app displays a QR code and the mobile signer app initiates the connection.

---

## Architecture Overview

**Participants:**
- **TV App (Client)**: Displays QR code, receives signed events
- **Relay**: WebSocket server that relays encrypted messages between client and signer
- **Signer App** (e.g., Amber on Android): Holds user's private keys, signs events on request

**Protocol:**
- All communication uses **kind 24133** Nostr events
- Message payloads are encrypted using **NIP-44 v2** (ChaCha20-Poly1305)
- The client generates an ephemeral keypair for each session

---

## Phase 1: App Initialization

On app launch:
1. Check for a persisted bunker session in local storage
2. If a valid session exists (not expired, typically < 30 days):
   - Mark user as authenticated immediately
   - Load cached profile data for instant UI
   - In background: restore the bunker connection using saved credentials
3. If no session exists, show unauthenticated state with login option

---

## Phase 2: User Initiates Login

**View: Welcome/Login Screen**

User taps "Sign in with nsec bunker" or similar button. This navigates to the bunker login view.

---

## Phase 3: Generate Connection URI and QR Code

**View: Bunker Login Screen (Connecting State)**

1. **Generate Ephemeral Client Keypair**
   - Create a new random Nostr keypair
   - This keypair is only used for encrypted communication with the signer
   - Store the private key for later (needed for session restoration)

2. **Generate Random Secret**
   - Create a UUID or random string
   - This validates that the correct signer responded

3. **Build nostrconnect:// URI**
   ```
   nostrconnect://<client-public-key>?relay=<relay-url>&secret=<secret>&name=<app-name>&url=<app-url>
   ```
   - `client-public-key`: hex pubkey from step 1
   - `relay`: URL-encoded relay address (e.g., `wss://relay.primal.net`)
   - `secret`: the random string from step 2
   - `name`: your app name (e.g., "nostrTV")
   - `url`: your app URL (optional)

4. **Generate QR Code Image**
   - Encode the URI as a QR code
   - Display at high resolution for TV scanning distance

5. **Connect to Relay**
   - Open WebSocket connection to the specified relay
   - Subscribe to kind 24133 events with a p-tag filter matching your client public key

---

## Phase 4: Display QR Code and Wait

**View: Bunker Login Screen (Waiting for Scan State)**

- Display the QR code prominently
- Show instructions: "Scan with Amber, Amethyst, or compatible signer"
- Start a timeout (e.g., 3 minutes) for the user to scan
- Listen for incoming kind 24133 events on the relay subscription

---

## Phase 5: Signer App Processes QR Code

**On the mobile signer app (user's phone):**

1. User scans the QR code
2. Signer extracts the nostrconnect:// URI components
3. Signer prompts user to approve the connection request
4. User approves
5. Signer sends a kind 24133 event to the specified relay:
   - `pubkey`: signer's public key
   - `tags`: `[["p", "<client-pubkey>"]]`
   - `content`: NIP-44 encrypted JSON response containing the secret or "ack"

---

## Phase 6: Receive and Validate Connection

**View: Bunker Login Screen (Waiting for Approval State)**

When a kind 24133 event arrives:

1. **Extract sender info**
   - Store the signer's public key (needed for all future communication)
   - Update UI to show "Approve the connection on your phone"

2. **Decrypt the message**
   - Use NIP-44 v2 decryption
   - Key derivation: your client private key + signer's public key

3. **Parse the response**
   - Expected format: `{"id": "...", "result": "<secret-or-ack>", "error": null}`

4. **Validate the secret**
   - Check that `result` equals your generated secret OR equals "ack"
   - If mismatch, ignore and keep waiting (could be replay or wrong signer)
   - If valid, proceed to next phase

---

## Phase 7: Fetch User's Public Key

After connection is validated:

1. **Build NIP-46 RPC request**
   ```json
   {
     "id": "<random-uuid>",
     "method": "get_public_key",
     "params": []
   }
   ```

2. **Encrypt and send**
   - Serialize to JSON
   - Encrypt with NIP-44 (your private key -> signer's public key)
   - Create kind 24133 event with encrypted content
   - Add p-tag pointing to signer's pubkey
   - Publish to relay

3. **Wait for response** (with timeout, e.g., 90 seconds)
   - Track pending requests by ID
   - When response arrives, decrypt and match by ID
   - Extract user's Nostr public key from the `result` field

---

## Phase 8: Complete Authentication

**View: Bunker Login Screen (Connected State)**

1. **Update UI**
   - Show success indicator (checkmark)
   - Display "Connected! Fetching your profile..."

2. **Create and persist session**
   ```
   BunkerSession {
     bunkerPubkey: <signer's public key>
     relay: <relay URL>
     userPubkey: <user's Nostr public key>
     clientPrivateKey: <your ephemeral private key - CRITICAL>
     createdAt: <timestamp>
     lastUsed: <timestamp>
   }
   ```
   - **Important**: You must save the client private key to restore sessions later

3. **Update app authentication state**
   - Set user as authenticated
   - Store user's public key for profile fetching

---

## Phase 9: Load and Display Profile

**View: Profile Confirmation Screen**

1. **Fetch user profile from Nostr**
   - Connect to content relays
   - Request kind 0 (metadata) event for user's pubkey
   - Parse profile picture, display name, etc.

2. **Display confirmation**
   - Show profile picture
   - Show display name / username
   - Show "Log In" button to confirm

3. **Cache profile data**
   - Save to local storage for faster startup next time

4. **Navigate to main app**
   - Dismiss login flow
   - Show authenticated home screen

---

## Phase 10: Signing Events (Ongoing Usage)

When user performs actions requiring signatures (zaps, chat messages):

1. **Build unsigned event**
   ```
   {
     kind: <event-kind>,
     tags: [...],
     content: "...",
     created_at: <unix-timestamp>
   }
   ```

2. **Send sign_event request**
   ```json
   {
     "id": "<uuid>",
     "method": "sign_event",
     "params": ["<event-json-string>"]
   }
   ```

3. **Encrypt and publish** (same as Phase 7)

4. **Wait for signed event**
   - Response contains the fully signed event with `id`, `pubkey`, and `sig` fields
   - Use this signed event for publishing to relays

---

## Phase 11: Session Restoration (App Relaunch)

On subsequent app launches:

1. **Load persisted session** from storage

2. **Immediately show authenticated state**
   - Use cached profile data
   - Don't block UI on reconnection

3. **Restore bunker connection in background**
   - Create new bunker client instance
   - **Restore the saved client keypair** (this is why we saved it)
   - Connect to the saved relay
   - Subscribe to kind 24133 events
   - Set bunker pubkey from session

4. **Start health monitoring**
   - Periodically send `ping` requests (every 60 seconds)
   - If ping fails, attempt automatic reconnection

---

## Phase 12: Health Check and Reconnection

**Ongoing during authenticated session:**

1. **Ping periodically**
   - Send NIP-46 `ping` method every 60 seconds
   - If no response, mark connection as unhealthy

2. **Auto-reconnect on failure**
   - Reconnect WebSocket to relay
   - Re-subscribe to kind 24133 events
   - If reconnection fails repeatedly, show error UI

---

## Phase 13: Logout

When user logs out:

1. **Send disconnect request** (optional, graceful)
   ```json
   {"id": "...", "method": "disconnect", "params": []}
   ```

2. **Close WebSocket connection**

3. **Clear persisted session** from storage

4. **Clear cached profile data**

5. **Reset authentication state**

6. **Navigate to welcome screen**

---

## Connection States

Track these states for UI updates:

| State | Description | UI Display |
|-------|-------------|------------|
| `disconnected` | No active session | Show login button |
| `connecting` | Setting up relay connection | Show spinner + "Connecting..." |
| `waitingForScan` | QR displayed | Show QR + "Scan the code" |
| `waitingForApproval` | Signer scanned | Show spinner + "Approve on phone" |
| `connected` | Successfully authenticated | Show checkmark + "Connected!" |
| `error` | Connection failed | Show error message + retry option |

---

## Encryption Details (NIP-44 v2)

For all encrypted communication:

- **Algorithm**: ChaCha20-Poly1305 AEAD
- **Key derivation**: Shared secret from ECDH (secp256k1) + HKDF
- **Conversation key**: Derived from (your private key, their public key)
- **Padding**: Variable-length padding for privacy
- **Format**: Version byte + nonce + ciphertext + auth tag

Use a NIP-44 library for your platform rather than implementing from scratch.

---

## Supported NIP-46 Methods

| Method | Purpose | Params |
|--------|---------|--------|
| `connect` | Signer initiates response | `[pubkey, secret?]` |
| `get_public_key` | Get user's pubkey | `[]` |
| `sign_event` | Sign a Nostr event | `[event_json]` |
| `ping` | Health check | `[]` |
| `disconnect` | Close session | `[]` |

---

## Timeouts

| Operation | Suggested Timeout |
|-----------|-------------------|
| Initial QR scan | 3 minutes |
| RPC requests (sign_event, get_public_key) | 90 seconds |
| Health check interval | 60 seconds |
| Session expiry | 30 days |

---

## Error Handling

Handle these scenarios gracefully:

- **Invalid URI**: Malformed nostrconnect:// URL
- **Timeout**: User didn't scan or approve in time
- **Secret mismatch**: Wrong signer responded
- **Remote error**: Signer returned an error in response
- **Connection lost**: WebSocket disconnected
- **Decryption failed**: Key mismatch or corrupt message

---

## Critical Implementation Notes

1. **Save the client private key** - Without this, you cannot restore sessions
2. **Use the same relay** for all bunker communication in a session
3. **Track pending requests by ID** - Responses may arrive out of order
4. **Validate the secret** - Prevents unauthorized signers from connecting
5. **Handle reconnection gracefully** - Network on TV may be unreliable
6. **Cache profile data** - Improves perceived performance on app launch
7. **NIP-44 v2 only** - Don't use NIP-04 (older, less secure)

---

This flow provides secure, user-friendly remote signing where private keys never leave the user's mobile device while still enabling full Nostr functionality on the TV app.
