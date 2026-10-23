# iPhone port checkpoint

Implementation and simulator verification completed on October 22, 2026.
Branch: `feature/iphone-app`. Changes are saved locally and uncommitted.
Preexisting staged TV icon metadata, workspace state, `.DS_Store`, and the
Xcode Cloud manifest have been preserved.

## Implemented

- Separate `CoveIOS` app target in this repository, sharing the Nostr, authentication,
  chat, playback, and zap services with the Apple TV app.
- Native discovery, following, account, sign-in, creator, playback, chat, and zap flows.
- Adaptive watch layout: open portrait places video above chat; sufficiently wide
  landscape places chat beside video. Playback session and draft survive reflow.
- Native player controls, AirPlay, picture in picture, and background audio.
- Xcode updated to 27.1 (27A9275); iOS 27.1 runtime installed.

## Verified

- iPhone unit tests: 9 passed (`/private/tmp/cove-duo-unit.xcresult`).
- Standard iPhone UI tests: 2 passed with a local video fixture, including rotation,
  playback-clock continuity, draft preservation, and portrait video/chat ordering
  (`/private/tmp/cove-iphone-final.xcresult`, also includes the 9 unit tests).
- Native Duo hinge/rotation test passed, including open portrait with the keyboard,
  closing to portrait, player identity, advancing playback clock, and draft
  preservation (`/private/tmp/cove-duo-final.xcresult`). The earlier manually
  operated runs include transition/timeout failures; the final run passed.
- Apple TV regression: 65 tests passed (`/private/tmp/cove-tv-final-port.xcresult`).
- iPhone Debug builds succeeded for device and simulator; unsigned device Release
  build passed (`/private/tmp/cove-ios-release.log`).
- Release app uses the iOS 27.1 SDK, supports iPhone on iOS 18+, includes audio
  background mode, and excludes debug fixture switches, playback probes, and media.

## Device acceptance and distribution

The port has not been submitted to the App Store. Configure signing and test a
real signer/wallet handoff, background audio, AirPlay, and picture in picture on
physical hardware before distribution. No real identity or payment was used by
the offline simulator checks.

See `IPHONE_APP.md` for setup, shared-code membership, and repeatable test steps.
The hinge test needs Device Hub's native controls; ordinary tests skip it. Screenshots
capture all active displays because application screenshots alone can capture the
inactive outer display while Duo is open.
Upright open/closed captures are saved in `screenshots/iphone/` and displayed in
the setup guide. They use the local test video and sample chat.

Build cache: `/private/tmp/nostrTV-profiles-20261021/SourcePackages`.
iPhone test derived data: `/private/tmp/cove-duo-tests`.
Xcode products are stored on the external drive under
`/Volumes/Extranl Drive/Xcode/Product`.

Xcode's current simulator reports a runtime warning for the synchronous
`AVAudioSession.setActive` call on the main actor. Playback checks pass; migrating
audio activation to the newer asynchronous API is a performance follow-up.

## Duo interface refinement — October 23, 2026

On `feature/iphone-app`, the home screen now uses a minimized native search
control, compact title, tab-bar-first presentation, and even, top-aligned grid
columns. Search follows `toolbarVerticalEdge`: side placement when the system
offers vertical bars, top trailing placement with horizontal bars so the tab bar
cannot hide it in open portrait.

The player replaces Done with a labelled back chevron, removes the navigation
title/header, extends the picture to the top edge, and fits landscape video at
the top of its column. Open portrait continues to place video above chat, with
native horizontal controls floating over the picture, as Apple's guidance
specifies. Horizontal safe areas and keyboard avoidance remain active.

Validation for the player/search changes:

- Build for testing passed with Xcode 27.1.
- 10 unit tests and 2 ordinary UI tests passed; the latter now verify search
  expansion/filtering, Back semantics and top-edge video placement
  as well as existing navigation, rotation, chat and playback checks:
  `/private/tmp/cove-duo-ui-refinement.xcresult`.
- Native open/rotate/close playback and draft test passed in 54.441 seconds:
  `/private/tmp/cove-duo-ui-hinge.xcresult`.

Updated captures are in `screenshots/iphone/duo-refinement/`. They use sample
streams and a local test video; the earlier gallery remains for comparison.
Apple references and the portrait toolbar exception are recorded in
`IPHONE_APP.md`.
