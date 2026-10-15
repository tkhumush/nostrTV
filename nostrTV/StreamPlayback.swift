import Foundation

/// AVPlayer consumes the complete HLS multivariant playlist. Keeping it intact
/// lets AVFoundation select and synchronize separate audio/video renditions.
enum StreamPlayback {
    private static func remoteURL(_ source: String) -> URL? {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", host != "127.0.0.1", host != "::1" else { return nil }
        return url
    }

    static func nativeURL(_ source: String) -> URL? {
        guard let url = remoteURL(source),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["m3u8", "mp4", "m4v", "mov", "m4a", "mp3"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    static func preferredSource(_ sources: [String]) -> String? {
        let native = sources.compactMap(nativeURL)
        // Prefer adaptive HLS; never extract a video-only variant from its master.
        return (native.first { $0.pathExtension.lowercased() == "m3u8" } ?? native.first)?.absoluteString
            ?? sources.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func isDiscoverable(_ source: String) -> Bool {
        guard let url = remoteURL(source) else { return false }
        return nativeURL(source) != nil || url.scheme?.lowercased() == "moq" ||
            (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.pathExtension.lowercased() == "mpd")
    }

    static func unavailableMessage(for source: String) -> String {
        if URL(string: source)?.scheme?.lowercased() == "moq" {
            return "This broadcaster only offers MoQ. Cove needs an HLS stream to play it on Apple TV."
        }
        if URL(string: source)?.pathExtension.lowercased() == "mpd" {
            return "This broadcaster only offers MPEG-DASH. Cove needs an HLS stream to play it on Apple TV."
        }
        return "This broadcast doesn’t include a supported playback URL. Try another stream."
    }
}
