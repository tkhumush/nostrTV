import Foundation
import Testing
import UIKit
@testable import nostrTV

struct ArtworkTests {
    @Test func ignoresEmptyAndMalformedSourcesWithoutLosingFallbacks() {
        let urls = ArtworkSource.urls([nil, "  ", "/relative.jpg", "ftp://example.com/art.jpg",
            " https://example.com/thumb.webp ", "https://example.com/thumb.webp", "https://example.com/avatar.jpg"])
        #expect(urls.map(\.absoluteString) == ["https://example.com/thumb.webp", "https://example.com/avatar.jpg"])
    }

    @Test func skipsFailedAndUndecodableResponsesThenCachesFallback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = ImageCache(session: session)
        let missing = URL(string: "https://artwork.example/missing")!
        let invalid = URL(string: "https://artwork.example/invalid")!
        let thumbnail = URL(string: "https://artwork.example/thumbnail")!
        let image = await cache.loadImage(from: [missing, invalid, thumbnail])
        #expect(image != nil)
        #expect(await cache.image(for: missing) == nil)
        #expect(await cache.image(for: invalid) == nil)
        #expect(await cache.image(for: thumbnail) != nil)
    }

    @Test func omittedArtworkDoesNotEraseExistingBannerOrThumbnail() {
        var previous = Stream(streamID: "live", eventID: nil, title: "Live", streaming_url: "https://example.com/live.m3u8",
            imageURL: "https://example.com/banner.jpg", pubkey: "host", eventAuthorPubkey: "host", profile: nil,
            status: "live", tags: [], createdAt: nil, viewerCount: 1, recording: nil, startsAt: nil,
            thumbnailURL: "https://example.com/thumb.webp")
        var update = previous
        update.imageURL = " "
        update.thumbnailURL = nil
        let merged = update.preservingDisplayFields(from: previous)
        #expect(merged.imageURL == previous.imageURL)
        #expect(merged.thumbnailURL == previous.thumbnailURL)
        let profile = Profile(pubkey: "host", name: "Host", displayName: nil, about: nil,
            picture: "https://example.com/avatar.jpg", nip05: nil, lud16: nil)
        previous = previous.attachingProfile(profile)
        #expect(previous.artworkURLs(profile: nil).count == 3)
        #expect(previous.thumbnailURL == merged.thumbnailURL)
    }

    @Test func transientAvatarFailureRetriesWithoutNeedingAnotherAppearance() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = ImageCache(session: session)
        let url = URL(string: "https://artwork.example/\(UUID().uuidString)/transient")!
        #expect(await cache.loadImage(from: url) != nil)
        #expect(await cache.image(for: url) != nil)
    }
}

private final class ArtworkURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var attempts: [URL: Int] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let attempt = Self.lock.withLock {
            Self.attempts[url, default: 0] += 1
            return Self.attempts[url]!
        }
        let status = url.lastPathComponent == "missing" ? 404 :
            (url.lastPathComponent == "transient" && attempt == 1 ? 503 : 200)
        // A valid PNG on a 404 must still be rejected; a 200 HTML page must not decode.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        let data = url.lastPathComponent == "invalid" ? Data("<html>Unavailable</html>".utf8) : png
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
