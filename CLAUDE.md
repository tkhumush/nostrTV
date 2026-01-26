# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

nostrTV is a native Apple TV application that displays live video streams from the Nostr protocol. The app connects to multiple Nostr relays to discover live streams and allows users to watch them directly on Apple TV with integrated Lightning address zap support.

## Build Commands

### Basic Operations
- **Build the app**: `xcodebuild -project nostrTV.xcodeproj -scheme nostrTV -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" build`
- **Run tests**: `xcodebuild -project nostrTV.xcodeproj -scheme nostrTV -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" test`
- **Clean build**: `xcodebuild -project nostrTV.xcodeproj -scheme nostrTV clean`

### Available Targets
- `nostrTV` - Main application target
- `nostrTVTests` - Unit tests
- `nostrTVUITests` - UI tests

## Architecture Overview

### Core Components

**NostrClient** (`nostrTV/NostrClient.swift`)
- Manages WebSocket connections to multiple Nostr relays
- Handles Nostr event parsing for both live streams (kind 30311) and profiles (kind 0)
- Connected relays: relay.snort.social, relay.tunestr.io, relay.damus.io, relay.primal.net
- Automatically requests user profiles when streams are discovered

**StreamViewModel** (`nostrTV/StreamViewModel.swift`)
- Central state management for stream data
- Handles stream deduplication and refresh functionality
- Bridges NostrClient events to SwiftUI views

**ContentView** (`nostrTV/ContentView.swift`)
- Main UI displaying stream list with thumbnails and user profiles
- Implements fullscreen video player presentation
- Shows profile pictures, usernames, and Lightning addresses

**VideoPlayerView** (`nostrTV/VideoPlayerView.swift`)
- Wraps AVPlayerViewController with custom functionality
- Displays app logo overlay and Lightning QR codes for zapping
- Implements CustomAVPlayerViewController that disables idle timer during playback

**Stream** (`nostrTV/Stream.swift`)
- Data model for live stream objects with Codable, Identifiable conformance

**Profile** (`nostrTV/Profile.swift`)
- Data model for Nostr user profiles including Lightning addresses (lud16)

### Key Features
- Multi-relay Nostr protocol integration for stream discovery
- Real-time profile fetching and display
- Lightning Network zap support via QR codes
- Apple TV optimized interface with thumbnail previews
- Hardware-accelerated video playback
- Automatic stream refresh and deduplication

### tvOS Specific Considerations
- **Deployment Target**: tvOS 18.0+ (configured in project settings)
- **UI Design**: Optimized for 10-foot interface with large touch targets
- **Focus Management**: Leverages tvOS focus engine for navigation
- **Idle Timer**: Disabled during video playback to prevent sleep

### Recent Additions
- QR Code generation for Lightning zap support
- Profile picture and username display in stream listings
- Multi-relay connection support for improved stream discovery
- Enhanced stream metadata extraction from Nostr events

### Dependencies
- SwiftUI for declarative UI
- AVKit for video playback
- CoreImage for QR code generation
- Foundation URLSessionWebSocketTask for Nostr relay connections

### Development Notes
- The app uses SwiftUI with UIKit integration for video player components
- All Nostr communication is handled via WebSocket connections
- Profile data is cached locally during app session
- Stream URLs are validated before playback
- No external package dependencies - uses only iOS/tvOS system frameworks

## Documentation

### Live Chat Architecture
**IMPORTANT**: Before working on live chat features, read `docs/LIVE_CHAT_ARCHITECTURE.md`

This document contains:
- Analysis of Primal iOS app's reliable chat implementation
- Root causes of chat reliability issues
- Comprehensive implementation plan with code patterns
- Comparison with nostrdb (not recommended for this use case)

Key findings:
- Use singleton `ChatConnectionManager` pattern (not per-view ChatManager)
- Store handlers per subscription ID (avoid global callback overwriting)
- Implement RAII-style cleanup via `deinit`
- Add heartbeat monitoring and exponential backoff reconnection
- Buffer messages until EOSE (End of Stored Events)

### Nostr Event Kinds Used
| Kind | Name | Purpose |
|------|------|---------|
| 0 | Metadata | User profiles |
| 30311 | Live Event | Stream metadata |
| 1311 | Live Comment | Chat messages |
| 9735 | Zap Receipt | Payment receipts |