//
//  Stream.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import Foundation

enum StreamStatus: String, Codable {
    case live = "live"
    case ended = "ended"
    case planned = "planned"
    case unknown = "unknown"

    init(from string: String) {
        self = StreamStatus(rawValue: string) ?? .unknown
    }
}

struct Stream: Identifiable, Codable, Equatable {
    let streamID: String  // The "d" tag identifier
    let eventID: String?  // The actual Nostr event ID (for zap references)
    let title: String
    let streaming_url: String
    let imageURL: String?
    let pubkey: String?  // Host pubkey (from p-tag) - used for profile display
    let eventAuthorPubkey: String?  // Event author pubkey (event signer) - used for a-tag coordinates
    let profile: Profile?
    let status: String
    let tags: [String]
    let createdAt: Date?
    let viewerCount: Int  // Current viewer/participant count
    let recording: String?  // Recording URL from "recording" tag
    let startsAt: Date?     // From "starts" tag (unix timestamp)

    /// Relays this stream's chat lives on, from the NIP-53 "relays" tag.
    ///
    /// Kind 30311 announcements propagate widely, but the kind 1311 chat messages
    /// and kind 9735 zap receipts for a stream are usually published only to these
    /// relays. Without connecting to them the chat subscription is well-formed but
    /// returns nothing. Defaults to empty for streams that omit the tag.
    var relays: [String] = []

    var id: String { streamID }

    var isLive: Bool {
        return status == "live"
    }

    /// NIP-33 addressable event coordinate (for deletion matching).
    /// Normalized via `ATag` so it compares equal to coordinates carried by
    /// kind 5 deletion events regardless of pubkey casing.
    var aTag: String {
        ATag.construct(pubkey: eventAuthorPubkey ?? "", dTag: streamID)
    }

    var category: String {
        // Determine category based on tags
        if tags.contains(where: { ["music", "audio", "song", "band", "concert", "radio"].contains($0.lowercased()) }) {
            return "Music"
        } else if tags.contains(where: { ["gaming", "game", "esports", "stream", "twitch"].contains($0.lowercased()) }) {
            return "Gaming"
        } else if tags.contains(where: { ["talk", "podcast", "interview", "discussion", "chat"].contains($0.lowercased()) }) {
            return "Talk Shows"
        } else if tags.contains(where: { ["education", "learning", "tutorial", "tech", "programming", "coding"].contains($0.lowercased()) }) {
            return "Education"
        } else if tags.contains(where: { ["news", "politics", "current", "events", "breaking"].contains($0.lowercased()) }) {
            return "News"
        } else if tags.contains(where: { ["art", "creative", "design", "drawing", "painting"].contains($0.lowercased()) }) {
            return "Art & Creative"
        } else if tags.contains(where: { ["sports", "football", "basketball", "soccer", "tennis"].contains($0.lowercased()) }) {
            return "Sports"
        } else if !tags.isEmpty {
            return "Other"
        } else {
            return "General"
        }
    }

    static func == (lhs: Stream, rhs: Stream) -> Bool {
        return lhs.streamID == rhs.streamID
    }
}
