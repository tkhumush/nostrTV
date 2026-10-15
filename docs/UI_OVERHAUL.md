# Cove native UI overhaul

Branch: `codex/ui-overhaul`, based on `dev` at `dc06e99`.
Design reference: the approved local HTML prototype on `codex/cove-ui-prototype` (`ec09a08`).

## Implemented

- A Cove navigation bar, featured broadcast, category filters derived from actual stream tags, and consistent four-column thumbnail shelves. Live cards keep their positions while relay updates arrive; new streams append and ended streams leave the live shelf.
- Separate signed-out, loading, empty Discover, and empty/missing Following states. Available recordings remain accessible under Catch up and open their recording URL.
- A video-first player with optional chat, cinema mode, custom remote controls, and a separate native playback-options surface for seeking, audio, and subtitles. Actual video keeps its aspect ratio. The same AVPlayer and controller survive chat and creator-panel changes.
- A single creator/zap panel on the right, retaining real invoice generation and receipt matching. Background controls surrender focus while it is open. Closing the panel returns focus to its opener. Leaving an invoice cancels pending UI work and closes its receipt subscription.
- Readable chat with inline zap acknowledgments instead of a permanent ticker. Read history stops automatic scrolling; Jump to live resumes it. Profile changes do not force scroll. Message failures leave the draft available and show an error.
- Your space with the existing sign-in/profile flow, profile refresh, sign-out, and a persistent default-chat preference. Focus effects honor the Apple TV accessibility Reduce Motion setting.
- Cached avatars, stable artwork placeholders, and high-contrast focus outlines. Attaching a profile to a selected stream preserves its custom relays, recording URL, and event coordinates.

## Deliberate differences from the HTML study

- Real titles, profiles, categories, artwork, and counts replace the prototype's sample copy and photography.
- The app currently reads follows but has no safe follow-list publishing path. The panel shows existing follow status and directs users to follow in their Nostr app. It does not pretend to publish a follow.
- Cinema is explicitly selected. Normal controls remain available while using chat; automatic timed control hiding is not included in this change.
- No release version or build number has changed. Archive, signing validation, TestFlight upload, and merging to main are later session steps.

## Validation

- Debug simulator compilation passed.
- Unsigned Release build for generic tvOS passed with the project's tvOS 26 deployment target.
- 43 tests passed: 41 unit tests and 2 native UI tests. Coverage includes stable card ordering, preserved relay metadata, chat hide/show, zap-panel focus restoration, cinema Back behavior, signed-out Following, and persisted chat preferences.
- Native screenshots were inspected at 1920 × 1080, including the visible focus ring and long card titles.
- The only installed simulator runtime is tvOS 18.5. Tests use `TVOS_DEPLOYMENT_TARGET=18.5` as a command-line override during `build-for-testing`, followed by `test-without-building` against the resulting `.xctestrun`. The project remains set to tvOS 26.
- UI tests use Debug-only `--cove-ui-testing` fixtures. This mode skips account restoration, relays, streaming video, and invoices. It is excluded from Release builds.

Before release, verify on Apple TV with actual streams: playback and native transport options, signed-in chat, reading history while new messages arrive, stream switching, reconnecting, long titles, absent artwork, remote signing, and generating/scanning a real zap invoice. The simulator checks do not establish live network or payment success.
