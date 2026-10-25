# Nsec and remote-signer security audit

Date: 2026-10-24; updated 2026-10-25 for PR verification and connection-key lifecycle checks. Scope: current Cove iOS and nostrTV sources, shared credential/signing services, and pinned key/crypto/relay dependency paths. This is a source audit with simulator regression checks, not a claim that all possible leakage or compromise has been ruled out.

## Findings and remediation

| Finding | Impact | Remediation |
| --- | --- | --- |
| BunkerSession encoded its client private key into UserDefaults | The remote-signing credential could enter ordinary preferences and backups | Entire session now stored in app-scoped Keychain. Legacy preferences are removed and migrated; failed migration requires sign-in again rather than retaining plaintext. |
| Failed handshake logged prefixes of the expected secret and returned result | Pairing secrets could appear in device logs | Removed secret/result interpolation and response IDs; remote rejection text is no longer displayed verbatim. |
| AuthMethod published complete private-key/session objects | UI observers and diagnostics could retain secret copies for the full session | Published auth method now contains only a method discriminator. Direct signing loads the key from Keychain per operation and checks it matches the signed-in public key. |
| Keychain save deleted before adding | Failure during replacement could lose the existing credential | Update by class/service/account identity; add only when absent. Explicitly disable synchronization. |
| Sign-out ignored deletion failures | UI could report signed out while credentials remained restorable | Both credential deletions are checked, missing items count as success, failure keeps sign-out available and displays an error. Successful sign-out disconnects the signer and clears ephemeral keys. Signing and sign-out are serialized on the main actor. |
| Input and pairing state outlived its useful lifetime | Sensitive strings/QR credentials could remain in view state | Clear nsec on submission, departure and loss of active scene; secure fields disable correction/capitalization. Hide pairing QR while inactive and release URI/QR on departure. Cancel unfinished tvOS pairing tasks. |
| Remote-signing error raced timeout/disconnect | Same continuation could be resumed twice | Error path resumes only if the request is still pending. |

Keypair and bunker-session diagnostic descriptions/mirrors redact secrets. This is defense in depth, not protection against arbitrary process-memory inspection. The ephemeral-key manager no longer publishes the keypair and releases it after the bunker client takes ownership.

## Data-flow review

- Local nsec: SecureField → strict nsec parser → Keychain. Restoration derives only the public identity; AuthMethod does not retain the key. Each signing operation reads Keychain, derives the keypair, signs locally, and returns a public event.
- Local event serialization contains ID, public key, timestamp, kind, tags, content and signature. The private key is not an event field or relay request parameter. A regression test validates an actual generated signature and checks the JSON contains neither nsec nor private-key hex.
- Remote signing: the user's identity private key remains with their chosen signer. Cove generates a fresh temporary client key for every new pairing on both platforms. That key persists only for the saved connection so reconnecting after an app restart retains the authorized client identity. Signing out deletes the saved client key and clears the live client/ephemeral manager; the next pairing generates a different key. A regression test covers persistence, deletion, and rotation. A socket reconnect is not a deleted connection. Revocation performed in the external signer is enforced by that signer; signing out in Cove removes Cove’s local credential, and a subsequent new pairing uses a fresh key. Cove's client key encrypts NIP-44 requests and signs kind 24133 envelopes. The full client session belongs in Keychain because possession can permit remote signing within the signer's authorization policy.
- QR/open/share links contain a client public key and a short-lived pairing secret, not the identity nsec or client private key. Sharing the connection is an explicit user action. Treat that link as a pairing credential until consumed/expired.
- No app code copies nsec to the pasteboard, writes it to a file/cache, adds it to an outgoing URL, or sends it to analytics. The app's pasteboard write is a Lightning invoice. A current tracked-text scan found no full-length nsec literals.
- Reviewed pinned NostrSDK revision `32a5b05120e3356e680369d0ec52e32592953b2e`: key parsing/generation errors do not print the nsec or hex; NIP-44 encryption/decryption does not log plaintext/private keys. Relay messages may be logged by the SDK, but these paths receive public events or encrypted bunker envelopes, not local key objects. Parsing now rejects a wrong nsec prefix/length before calling the SDK.
- No permissive App Transport Security exception was found in the checked app configuration. Configured signing relays use `wss://`; NIP-44 additionally encrypts the signing RPC payload.

## Apple guidance and chosen policy

Both nsec and bunker-session items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with `kSecAttrSynchronizable = false`, in the app's own service/access group. Access requires an unlocked device; the items do not migrate to a different device. Device-bound is **not** the same as a promise that no encrypted backup copy can exist. [Apple: restricting Keychain accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility), [Apple: Keychain data protection](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web).

This retains a common iOS/tvOS policy without requiring an iPhone passcode or a biometric prompt for every chat message. A stricter iOS policy (`WhenPasscodeSetThisDeviceOnly` and user-presence access control) is a possible product change for stronger protection against someone who can already use an unlocked device. It would add a passcode requirement and authentication interaction; it is not implemented or claimed here.

Native Secure Enclave signing is unavailable for imported Nostr secp256k1 keys: Apple's documented API uses generated P-256 keys and cannot import preexisting private keys. Do not describe these nsec keys as Secure Enclave keys. [Apple: protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave).

Sensitive input uses SecureField. Clearing input when inactive and obscuring pairing QR content reduces app-switcher exposure. `privacySensitive()` alone is not relied on as a screenshot-prevention mechanism. [Apple: SecureField](https://developer.apple.com/documentation/swiftui/securefield), [Apple: task-switcher snapshots](https://developer.apple.com/library/archive/qa/qa1838/_index.html).

## Verification

- Signed iPhone simulator unit suite: **22 tests passed, 1 opt-in hardware test skipped**, including real Keychain create/update/read/delete, inspection of accessibility and synchronization attributes, and connection-key persistence/deletion/rotation. PR verification: `/private/tmp/cove-security-pr-ios.log`.
- Tests exercise legacy migration, failure purging, failed saves/deletes, unavailable Keychain reads, mismatched account keys, invalid input, valid signatures and absence of keys in public event JSON, sign-out, local/remote switching, and redacted diagnostics.
- The unsigned simulator run failed the Keychain integration test. Re-running the same test in an ad-hoc signed simulator host succeeded. Do not skip or mock the real Keychain test to hide this configuration requirement.
- iPhone UI test: **passed**. Checks that entered text is masked, backgrounding clears the field, and the empty form cannot submit. PR verification: `/private/tmp/cove-security-pr-ios.log`.
- tvOS app and test bundle: `build-for-testing` succeeded. There is no available tvOS simulator runtime on this host; tvOS execution is not claimed.
- Production iOS Release build: **succeeded**, with signing disabled for compilation only. Evidence: `/private/tmp/cove-security-release.log`.
- `git diff --check` and full-length nsec scan of tracked text and passing test/build logs: clean.

## Boundaries and release checks

Swift String/Data and the pinned SDK can create copies of a private key. Scope reduction and reference release do not guarantee deterministic zeroization. Active bunker clients retain a client key while handling encrypted traffic. A compromised process, debugger, jailbroken device or malicious dependency can inspect memory; a remote signer is the appropriate choice when the user's identity key must never enter Cove memory.

The app cannot erase older external backups or logs already produced by a released build. If the prior bunker storage/logging behavior shipped, users concerned about exposure should revoke the old Cove authorization in their signer and reconnect. The defect stores the bunker client key, not the user's remote identity nsec.

Physical-device lock/unlock behavior, backup/restore to a second device, keyboard/remote-input behavior on Apple TV, and app-switcher/screen-recording behavior on hardware remain unverified. Hardware checks were deferred at the user’s request on 2026-10-25. They remain unverified; the software audit and passing simulator/build results do not establish hardware assurance. Simulator tests do not establish Secure Enclave/Data Protection hardware behavior. No historical-backup, device-log, or account-compromise investigation was performed.

### Reproducing the checks

Use the checked-in `CoveIOS` scheme with an available iPhone simulator. Run `CoveIOSTests` and `CoveIOSUITests/CredentialInputTests`. Keychain integration requires a signed simulator host (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`); use the app's normal signing settings on hardware. The corresponding tvOS tests are in `nostrTVTests/CredentialSecurityTests.swift` and can be run once a tvOS runtime is available. Test credentials are generated solely for tests, and the real Keychain test uses an isolated random service name.

Evidence logs for this audit are temporary local artifacts:

- `/private/tmp/cove-security-final-unit.log` — final unit suite.
- `/private/tmp/cove-security-verified.log` — passing UI privacy test and unit suite before the final actor annotation.
- `/private/tmp/cove-security-tv-final.log` — final tvOS app/test compilation.
- `/private/tmp/cove-security-release.log` — production iOS compilation.

## Prepared hardware check (deferred)

`CoveIOSTests/HardwareCredentialTests.swift` is disabled unless `COVE_TEST_DEVICE_LOCK=1`. It refuses simulator execution and requires an app identifier ending in `.securityaudit`. On a passcode-protected iPhone it verifies a generated credential is readable while unlocked, then asks the operator to lock the phone. Once protected data becomes unavailable it checks the real Keychain status is `errSecInteractionNotAllowed`, rather than confusing a missing item with lock protection. After the operator unlocks, it verifies the credential is readable again and deletes it. A time limit and background-execution expiry fail the test rather than silently skipping a missing lock transition. No personal key is used or printed.

The isolated project is prepared at `/private/tmp/cove-hardware-security-project/nostrTV.xcodeproj`. Its iOS app identifier is `duo.nostrTV.ios.securityaudit`, display name **Cove Audit**, with separate test bundle identifiers. Test-host launch arguments enable the offline fixture mode. `build-for-testing` for physical iOS succeeded with signing disabled; log: `/private/tmp/cove-hardware-security-build.log`. This proves compilation only. No app was installed on the paired iPhone, and no hardware test was executed. Signing, installation and operator-assisted lock/unlock were deferred at the user’s request on 2026-10-25. No installation approval is pending.
