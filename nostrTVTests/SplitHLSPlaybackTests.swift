import AVFoundation
import Network
import XCTest
@testable import nostrTV

/// Exercises AVPlayer on tvOS with a real, deterministic HLS master that points
/// to independent video and audio playlists. No internet or broadcaster needed.
final class SplitHLSPlaybackTests: XCTestCase {
    @MainActor
    func testPlaysVideoAndSelectsSeparateAudioRendition() async throws {
        try await assertPlaysSplitFixture { AVPlayerItem(url: $0) }
    }

    /// The app's own path: playlists are rewritten by `HLSPlaylistLoader`.
    @MainActor
    func testPlaysSplitRenditionsThroughPlaylistLoader() async throws {
        try await assertPlaysSplitFixture(StreamPlayback.playerItem(for:))
    }

    @MainActor
    private func assertPlaysSplitFixture(_ makeItem: (URL) -> AVPlayerItem) async throws {
        let bundle = Bundle(for: Self.self)
        _ = try XCTUnwrap(bundle.url(forResource: "cove-split-0-0.ts", withExtension: "bin"))
        _ = try XCTUnwrap(bundle.url(forResource: "cove-split-1-0.ts", withExtension: "bin"))
        let server = try HLSFixtureServer(bundle: bundle)
        let url = try await server.start()
        defer { server.stop() }
        let item = makeItem(url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.play()
        defer { player.pause() }

        var renderedFrame = false
        for _ in 0..<150 {
            if item.status == .failed { break }
            if player.currentTime().seconds > 0.25,
               output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil {
                renderedFrame = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))")
        XCTAssertTrue(renderedFrame, "The video rendition must decode and advance")
        let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
        XCTAssertNotNil(audio)
        if let audio { XCTAssertNotNil(item.currentMediaSelection.selectedMediaOption(in: audio)) }
        let requested = server.requestedFiles
        XCTAssertTrue(requested.contains("cove-split-0.m3u8"), "Video playlist must load")
        XCTAssertTrue(requested.contains("cove-split-1.m3u8"), "Separate audio playlist must load")
        XCTAssertTrue(requested.contains { $0.hasPrefix("cove-split-0-") && $0.hasSuffix(".ts") })
        XCTAssertTrue(requested.contains { $0.hasPrefix("cove-split-1-") && $0.hasSuffix(".ts") })
    }
}

private final class HLSFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let bundle: Bundle
    private let queue = DispatchQueue(label: "cove.hls.fixture")
    private let lock = NSLock()
    private var files = Set<String>()
    private var connections: [NWConnection] = []

    var requestedFiles: Set<String> { lock.withLock { files } }

    init(bundle: Bundle) throws {
        self.bundle = bundle
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/cove-split-master.m3u8")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let request = accumulated + data
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if !complete { self.receive(connection, accumulated: request) }
                else { connection.cancel() }
                return
            }
            let path = text.components(separatedBy: " ").dropFirst().first ?? ""
            let name = URL(string: "http://localhost\(path)")?.lastPathComponent ?? ""
            self.lock.withLock { _ = self.files.insert(name) }
            // Xcode treats .ts as source code; the transport segments are bundled
            // as .ts.bin and served under their original HLS names.
            let resource = self.bundle.url(forResource: name, withExtension: name.hasSuffix(".ts") ? "bin" : nil)
            let body = resource.flatMap { try? Data(contentsOf: $0) } ?? Data()
            let status = body.isEmpty ? "404 Not Found" : "200 OK"
            let type = name.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
