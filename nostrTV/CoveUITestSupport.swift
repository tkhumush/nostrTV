#if DEBUG
import Foundation

/// Offline fixtures are available only in Debug and only with this explicit launch argument.
/// They never restore an identity, connect to relays, sign events, or request invoices.
enum CoveUITestSupport {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--cove-ui-testing") }
    /// Only explicit offline tests can load a test runner's loopback media fixture.
    static var playbackFixtureURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard enabled, let index = arguments.firstIndex(of: "--cove-test-media"), index + 1 < arguments.count,
              let url = URL(string: arguments[index + 1]), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return url
    }
    static var streams: [Stream] {
        [
            ("An afternoon by the Pacific", "Coastline Radio", "music"),
            ("The internet we actually want", "Open Conversations", "talk"),
            ("After hours: vinyl only", "The Listening Room", "music"),
            ("A window into the woods", "Outside, Together", "art")
        ].enumerated().map { index, item in
            Stream(streamID: "preview-\(index)", eventID: "event-\(index)", title: item.0,
                streaming_url: "https://example.invalid/live.m3u8", imageURL: nil,
                pubkey: "host-\(index)", eventAuthorPubkey: "host-\(index)",
                profile: Profile(pubkey: "host-\(index)", name: item.1, displayName: item.1,
                                 about: "An independent voice. Live, together.", picture: nil, nip05: nil, lud16: nil),
                status: "live", tags: [item.2], createdAt: Date(), viewerCount: 128 - index * 20,
                recording: nil, startsAt: Date())
        }
    }
}
#endif
