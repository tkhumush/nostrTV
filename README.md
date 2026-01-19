# nostrTV

A native Apple TV application for watching live video streams from the Nostr protocol with integrated Lightning Network zap support.

![Platform](https://img.shields.io/badge/platform-tvOS%2018.0%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

## Overview

nostrTV brings decentralized live streaming to your living room. The app connects to multiple Nostr relays to discover live streams (NIP-53) and allows users to watch them directly on Apple TV. Viewers can support streamers by sending Lightning zaps with optional comments, all from the comfort of their couch.

## Features

- **Live Stream Discovery** - Automatically discovers live streams from multiple Nostr relays
- **Lightning Zaps** - Send sats to streamers via Lightning Network with QR code support
- **Live Chat** - Real-time chat messages alongside the stream
- **Zap Chyron** - Scrolling banner displaying recent zaps and comments
- **Nostr Login** - Sign in with your Nostr identity via NIP-46 Bunker connection
- **Profile Display** - Shows streamer profiles with pictures and Lightning addresses
- **Curated Feed** - Admin-curated discover feed for quality content
- **10-foot UI** - Optimized interface for TV viewing with Apple TV remote navigation

## Screenshots

<!-- Add screenshots here -->
*Coming soon*

## Requirements

- Apple TV 4K (2nd generation or later)
- tvOS 18.0 or later
- Xcode 15.0 or later (for development)

## Installation

### From Source

1. Clone the repository:
   ```bash
   git clone https://github.com/tkhumush/nostrTV.git
   cd nostrTV
   ```

2. Open the project in Xcode:
   ```bash
   open nostrTV.xcodeproj
   ```

3. Select your Apple TV device or simulator as the build target

4. Build and run (⌘R)

### Build Commands

```bash
# Build the app
xcodebuild -project nostrTV.xcodeproj -scheme nostrTV \
  -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" build

# Run tests
xcodebuild -project nostrTV.xcodeproj -scheme nostrTV \
  -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" test

# Clean build
xcodebuild -project nostrTV.xcodeproj -scheme nostrTV clean
```

## Usage

### Browsing Streams

1. Launch the app to see the **Discover** tab with curated live streams
2. Navigate using the Apple TV remote to browse available streams
3. Select a stream to start watching

### Watching a Stream

- **Chat Toggle** - Show/hide the live chat panel
- **Streamer Profile** - Click the streamer info to view their profile and follow
- **Send Chat** - Type a message and send to the live chat (requires login)

### Sending Zaps

1. Click on the streamer profile while watching
2. Select a zap amount
3. Scan the QR code with a Lightning wallet
4. Your zap will appear in the chyron banner

### Signing In

1. Go to Settings and select "Sign In"
2. Choose NIP-46 Bunker login
3. Scan the QR code with a compatible Nostr app (Amber, etc.)
4. Approve the connection request

## Architecture

### Core Components

| Component | Description |
|-----------|-------------|
| `NostrSDKClient` | Manages WebSocket connections to Nostr relays and event handling |
| `StreamViewModel` | Central state management for stream discovery and display |
| `StreamActivityManager` | Handles combined chat and zap subscriptions per stream |
| `VideoPlayerView` | Custom video player with chat, zap chyron, and streamer info |
| `NostrAuthManager` | Manages user authentication via NIP-46 Bunker |

### Nostr Event Kinds

| Kind | Name | Purpose |
|------|------|---------|
| 0 | Metadata | User profiles |
| 3 | Contacts | Follow lists |
| 30311 | Live Event | Stream metadata (NIP-53) |
| 1311 | Live Comment | Chat messages |
| 9735 | Zap Receipt | Lightning payment receipts |

### Connected Relays

- `wss://relay.snort.social`
- `wss://relay.tunestr.io`
- `wss://relay.damus.io`
- `wss://relay.primal.net`

## Tech Stack

- **SwiftUI** - Declarative UI framework
- **AVKit** - Hardware-accelerated video playback
- **NostrSDK** - Nostr protocol implementation
- **CoreImage** - QR code generation for Lightning invoices

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Nostr Protocol](https://nostr.com/) - The decentralized social protocol
- [NIP-53](https://github.com/nostr-protocol/nips/blob/master/53.md) - Live Activities specification
- [Lightning Network](https://lightning.network/) - Bitcoin's Layer 2 payment network
- Built with [NostrSDK](https://github.com/nostr-sdk/nostr-sdk-ios)

---

**nostrTV** - Decentralized streaming for the big screen
