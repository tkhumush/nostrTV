# nostrTV Project Context

## Project Overview
A native Apple TV application that displays live video streams from the Nostr protocol. The app connects to Nostr relays to discover live streams and allows users to watch them directly on Apple TV.

## Current Architecture

### Main Components

1. **nostrTVApp.swift**
   - Entry point of the application
   - Uses SwiftUI App lifecycle
   - Sets up ContentView as the main view

2. **ContentView.swift**
   - Main user interface displaying a list of live streams
   - Uses NavigationView and List to display streams
   - Implements video playback through fullScreenCover presentation
   - Features:
     - Stream thumbnails using AsyncImage
     - Refresh button to reload streams
     - Video player presentation when a stream is selected

3. **Stream.swift**
   - Data model representing a live stream
   - Conforms to Identifiable, Codable, and Equatable
   - Properties:
     - streamID: Unique identifier
     - title: Stream title
     - streaming_url: URL for the video stream
     - imageURL: Optional thumbnail image URL

4. **StreamViewModel.swift**
   - Manages the state for the stream list
   - Connects to NostrClient to receive stream updates
   - Handles deduplication of streams
   - Provides refresh functionality

5. **NostrClient.swift**
   - Handles WebSocket connections to Nostr relays
   - Processes incoming Nostr events (kind 30311 for live streams)
   - Extracts stream information from event tags
   - Relay connections:
     - wss://relay.snort.social
     - wss://relay.tunestr.io
     - wss://relay.damus.io
     - wss://relay.primal.net

6. **VideoPlayerView.swift**
   - Wraps AVPlayerViewController for SwiftUI
   - Uses UIViewControllerRepresentable
   - Features:
     - CustomAVPlayerViewController that disables idle timer
     - Logo overlay on video player
     - Automatic playback on presentation

### Key Features

- Live stream discovery via Nostr protocol
- Thumbnail images for streams
- Video playback with hardware acceleration
- Refresh functionality to reload streams
- Automatic deduplication of streams
- Apple TV optimized UI

### Dependencies

- SwiftUI
- AVKit
- Foundation
- URLSessionWebSocketTask for Nostr connections

## Current Functionality

1. On launch, the app connects to multiple Nostr relays
2. Requests live stream events (kind 30311)
3. Processes incoming events and extracts stream information
4. Displays streams in a list with thumbnails
5. When a stream is selected, opens fullscreen video player
6. Provides manual refresh capability

## Areas for Improvement

1. **Error Handling**
   - Network error handling for relay connections
   - Stream playback error handling
   - Graceful degradation when relays are unavailable

2. **User Experience**
   - Loading states for stream discovery
   - Better error messaging
   - Stream metadata display (viewer count, creator info)
   - Search/filter capabilities

3. **Performance**
   - Memory management for stream objects
   - Connection management for WebSocket relays
   - Image caching for thumbnails

4. **Video Playback**
   - Stream quality selection
   - Playback controls customization
   - Buffering indicators

5. **Nostr Integration**
   - Support for more relay types
   - Stream categorization
   - User following capabilities

## Planned Changes

### Short-term
- [ ] Add loading indicators during stream discovery
- [ ] Implement error handling for failed connections
- [ ] Add stream refresh interval settings
- [ ] Improve video player controls

### Medium-term
- [ ] Implement stream search/filter functionality
- [ ] Add stream categorization
- [ ] Enhance metadata display
- [ ] Add user preferences for relays

### Long-term
- [ ] Implement stream recording capabilities
- [ ] Add social features (comments, sharing)
- [ ] Support for multiple Nostr relay configurations
- [ ] Analytics dashboard for stream performance

## Development Notes

### Build Information
- Target: tvOS 15.0+
- Architecture: SwiftUI + UIKit integration for video player
- Xcode Project: nostrTV.xcodeproj

### Assets
- App Icon & Top Shelf Image
- Logo image overlay
- Accent color

### Testing
- Unit tests in nostrTVTests
- UI tests in nostrTVUITests

## Recent Changes
- Initial implementation of Nostr protocol integration
- Basic stream listing and playback functionality
- Multi-relay connection support

## Next Steps
1. Review and improve error handling
2. Enhance loading states and user feedback
3. Optimize performance for Apple TV hardware
4. Add more comprehensive stream metadata
