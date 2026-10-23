//
//  StreamStatsManager.swift
//  nostrTV
//
//  Audience totals for one live stream: viewers, likes (kind 7) and zaps (kind 9735).
//

import Foundation
import NostrSDK

/// A reaction (kind 7) to an addressable event, such as a live stream.
struct StreamReaction: Identifiable {
    let id: String
    let senderPubkey: String
    let content: String
    let streamATag: String
    let timestamp: Date

    /// NIP-25: "-" is a dislike; "+", an empty string and emoji are all likes.
    var isLike: Bool { content != "-" }
}

/// Deduplicating totals, kept apart from the chat timeline so they are not
/// limited by how many messages the chat keeps on screen.
struct StreamStatsTally {
    struct Supporter: Identifiable, Equatable {
        let pubkey: String
        var fallbackName: String?
        var sats: Int
        var id: String { pubkey }
    }

    private(set) var likeCount = 0
    private(set) var zapCount = 0
    private(set) var zapTotalSats = 0
    private var likers = Set<String>()
    private var zapIDs = Set<String>()
    private var supporters: [String: Supporter] = [:]

    /// Counts each person's like once, however many reactions they send.
    @discardableResult
    mutating func record(_ reaction: StreamReaction) -> Bool {
        guard reaction.isLike, likers.insert(reaction.senderPubkey.lowercased()).inserted else { return false }
        likeCount = likers.count
        return true
    }

    @discardableResult
    mutating func record(_ zap: ZapComment) -> Bool {
        guard zap.amountInSats > 0, zapIDs.insert(zap.id).inserted else { return false }
        zapCount += 1
        zapTotalSats += zap.amountInSats
        let key = zap.senderPubkey.lowercased()
        var supporter = supporters[key] ?? Supporter(pubkey: zap.senderPubkey, fallbackName: nil, sats: 0)
        supporter.sats += zap.amountInSats
        supporter.fallbackName = supporter.fallbackName ?? zap.senderName
        supporters[key] = supporter
        return true
    }

    func topSupporters(_ count: Int) -> [Supporter] {
        Array(supporters.values.sorted { $0.sats == $1.sats ? $0.pubkey < $1.pubkey : $0.sats > $1.sats }.prefix(count))
    }
}

/// Follows one stream's audience totals while it is open.
@MainActor
final class StreamStatsManager: ObservableObject {
    @Published private(set) var viewerCount: Int
    @Published private(set) var isLive: Bool
    @Published private(set) var tally = StreamStatsTally()
    /// Bumped when a supporter's profile arrives so names and pictures refresh.
    @Published private(set) var profileRevision = 0

    private let stream: Stream
    private let aTag: String
    private var client: NostrSDKClient?
    private var subscriptionIds: [String] = []
    private var callbackId: String?
    private var latestUpdate: Date?

    /// Large enough to total a long stream's zaps and likes; the chat keeps far fewer.
    private let historyLimit = 1000

    init(stream: Stream) {
        self.stream = stream
        self.aTag = ATag.normalize(stream.aTag)
        self.viewerCount = stream.viewerCount
        self.isLive = stream.isLive
        self.latestUpdate = stream.createdAt
    }

    func profile(for pubkey: String) -> Profile? { client?.getProfile(for: pubkey) }

    func startListening(using client: NostrSDKClient) {
        guard callbackId == nil, let author = stream.eventAuthorPubkey else { return }
        self.client = client
        let suffix = String(UUID().uuidString.prefix(8))
        let id = "stats-\(suffix)"
        callbackId = id

        client.addReactionReceivedCallback(forSubscriptionId: id) { [weak self] reaction in
            Task { @MainActor in self?.handle(reaction) }
        }
        client.addZapReceivedCallback(forSubscriptionId: id) { [weak self] zap in
            Task { @MainActor in self?.handle(zap) }
        }
        client.addStreamUpdateCallback(forSubscriptionId: id) { [weak self] update in
            Task { @MainActor in self?.handle(update) }
        }
        client.addProfileReceivedCallback(forSubscriptionId: id) { [weak self] profile in
            Task { @MainActor in self?.handle(profile) }
        }

        if let filter = Filter(kinds: [7, 9735], tags: ["a": [stream.aTag]], limit: historyLimit) {
            subscriptionIds.append(client.subscribe(with: filter, subscriptionId: id, purpose: "stream-stats"))
        }
        // Hosts republish the replaceable 30311 event as the audience changes.
        if let filter = Filter(authors: [author], kinds: [30311], tags: ["d": [stream.streamID]], limit: 1) {
            subscriptionIds.append(client.subscribe(with: filter, subscriptionId: "stats-live-\(suffix)", purpose: "stream-stats-live"))
        }
    }

    func stopListening() {
        for id in subscriptionIds { client?.closeSubscription(id) }
        if let callbackId { client?.removeCallback(forSubscriptionId: callbackId) }
        subscriptionIds = []
        callbackId = nil
    }

    private func handle(_ reaction: StreamReaction) {
        guard ATag.normalize(reaction.streamATag) == aTag else { return }
        tally.record(reaction)
    }

    private func handle(_ zap: ZapComment) {
        guard let zapATag = zap.streamEventId, ATag.normalize(zapATag) == aTag,
              tally.record(zap) else { return }
        if let client, client.getProfile(for: zap.senderPubkey) == nil {
            client.requestProfile(for: zap.senderPubkey)
        }
    }

    private func handle(_ update: Stream) {
        guard ATag.normalize(update.aTag) == aTag else { return }
        if let latestUpdate, let created = update.createdAt, created < latestUpdate { return }
        latestUpdate = update.createdAt ?? latestUpdate
        viewerCount = update.viewerCount
        isLive = update.isLive
    }

    private func handle(_ profile: Profile) {
        if tally.topSupporters(3).contains(where: { $0.pubkey.caseInsensitiveCompare(profile.pubkey) == .orderedSame }) {
            profileRevision += 1
        }
    }

    #if DEBUG
    /// Offline UI-test values. Never used with a relay connection.
    func showPreview() {
        var preview = StreamStatsTally()
        for index in 0..<42 {
            preview.record(StreamReaction(id: "like-\(index)", senderPubkey: "fan-\(index)", content: "+",
                                          streamATag: stream.aTag, timestamp: Date()))
        }
        let zaps = [("listener", "A listener", 21_000), ("coastline", nil, 5_000), ("outside", nil, 2_100), ("listener", "A listener", 1_000)]
        for (index, zap) in zaps.enumerated() {
            preview.record(ZapComment(id: "zap-\(index)", amount: zap.2 * 1000, senderPubkey: zap.0, senderName: zap.1,
                                      comment: "", timestamp: Date(), streamEventId: stream.aTag, bolt11: nil))
        }
        tally = preview
    }
    #endif
}
