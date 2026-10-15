import Foundation
import Testing
@testable import nostrTV

struct StreamPlaybackTests {
    @Test func selectsHLSRegardlessOfAnnouncementOrder() {
        let hls = "https://example.com/live.m3u8?token=signed"
        let moq = "moq://example.com:1443/"
        #expect(StreamPlayback.preferredSource([moq, hls]) == hls)
        #expect(StreamPlayback.preferredSource([hls, moq]) == hls)
        #expect(StreamPlayback.preferredSource(["https://example.com/live.mpd", hls]) == hls)
        #expect(StreamPlayback.nativeURL(hls)?.absoluteString == hls)
    }

    @Test func unsupportedTransportsNeverReachAVPlayer() {
        #expect(StreamPlayback.nativeURL("moq://example.com/") == nil)
        #expect(StreamPlayback.nativeURL("https://example.com/live.mpd") == nil)
        #expect(StreamPlayback.nativeURL("https://example.com/page?file=live.m3u8") == nil)
        #expect(StreamPlayback.nativeURL("http://localhost/live.m3u8") == nil)
        #expect(StreamPlayback.nativeURL("https://example.com/LIVE.M3U8") != nil)
        #expect(StreamPlayback.isDiscoverable("moq://example.com/"))
        #expect(StreamPlayback.unavailableMessage(for: "moq://example.com/").contains("MoQ"))
    }
}
