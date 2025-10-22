import Foundation
import AVFoundation

struct StreamCategory {
    let name: String
    let streams: [Stream]
}

class StreamViewModel: ObservableObject {
    @Published var streams: [Stream] = []
    @Published var categorizedStreams: [StreamCategory] = []
    @Published var allCategorizedStreams: [StreamCategory] = []  // Unfiltered streams
    private var nostrClient = NostrClient()
    private var refreshTimer: Timer?
    private var followList: [String] = []
    private var validationTasks: Set<String> = [] // Track ongoing validations

    // Stream collection size limit to prevent unbounded memory growth
    private let maxStreamCount = 200

    /// Expose the NostrClient for use by other components
    var client: NostrClient {
        return nostrClient
    }

    /// Get the featured stream (live stream with most viewers)
    var featuredStream: Stream? {
        let liveStreams = streams.filter { $0.isLive }
        // If following specific users, prioritize their streams
        if !followList.isEmpty {
            let followedLiveStreams = liveStreams.filter { stream in
                guard let pubkey = stream.pubkey else { return false }
                return followList.contains(pubkey)
            }
            if !followedLiveStreams.isEmpty {
                return followedLiveStreams.max(by: { $0.viewerCount < $1.viewerCount })
            }
        }
        // Otherwise return the stream with most viewers overall
        return liveStreams.max(by: { $0.viewerCount < $1.viewerCount })
    }

    init() {
        nostrClient.onStreamReceived = { [weak self] stream in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Always remove exact duplicates by streamID first
                self.streams.removeAll { existingStream in
                    existingStream.streamID == stream.streamID
                }

                // For live streams, prevent duplicates from the same pubkey
                // Only remove other LIVE streams from the same pubkey, not ended ones
                if stream.isLive, let pubkey = stream.pubkey {
                    self.streams.removeAll { existingStream in
                        existingStream.pubkey == pubkey && existingStream.isLive
                    }
                }

                self.streams.append(stream)

                // Evict old streams if we exceed the limit
                self.evictOldStreamsIfNeeded()

                self.updateCategorizedStreams()

                // Validate stream URL in background
                self.validateStreamURL(stream)
            }
        }

        startAutoRefresh()
    }

    func updateFollowList(_ newFollowList: [String]) {
        followList = newFollowList
        // Re-categorize streams with new follow filter
        updateCategorizedStreams()
    }

    deinit {
        stopAutoRefresh()
        nostrClient.disconnect()
    }

    private func startAutoRefresh() {
        // Initial connection
        nostrClient.connect()

        // Set up timer for automatic refresh every 30 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshStreams()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshStreams() {
        // Don't clear existing streams immediately - let new data come in and replace
        nostrClient.disconnect()
        nostrClient.connect()
    }

    /// Evict oldest ended streams when collection exceeds size limit
    private func evictOldStreamsIfNeeded() {
        guard streams.count > maxStreamCount else { return }

        // Calculate how many streams to remove (remove 20% to avoid frequent evictions)
        let excessCount = streams.count - maxStreamCount
        let removalCount = max(excessCount, Int(Double(maxStreamCount) * 0.2))

        // Separate live and ended streams
        let liveStreams = streams.filter { $0.isLive }
        let endedStreams = streams.filter { !$0.isLive }

        // If we have enough ended streams, remove oldest ones
        if endedStreams.count >= removalCount {
            // Sort ended streams by creation date (oldest first)
            let sortedEndedStreams = endedStreams.sorted { stream1, stream2 in
                guard let date1 = stream1.createdAt, let date2 = stream2.createdAt else {
                    return false
                }
                return date1 < date2
            }

            // Get IDs of streams to remove
            let streamsToRemove = Set(sortedEndedStreams.prefix(removalCount).map { $0.streamID })

            // Remove them from the collection
            streams.removeAll { streamsToRemove.contains($0.streamID) }
        } else {
            // If not enough ended streams, remove all ended streams and some oldest live streams
            let streamsToRemoveFromLive = removalCount - endedStreams.count

            // Keep all ended stream IDs for removal
            var streamsToRemove = Set(endedStreams.map { $0.streamID })

            // Sort live streams by creation date (oldest first)
            let sortedLiveStreams = liveStreams.sorted { stream1, stream2 in
                guard let date1 = stream1.createdAt, let date2 = stream2.createdAt else {
                    return false
                }
                return date1 < date2
            }

            // Add oldest live streams to removal set
            streamsToRemove.formUnion(sortedLiveStreams.prefix(streamsToRemoveFromLive).map { $0.streamID })

            // Remove them from the collection
            streams.removeAll { streamsToRemove.contains($0.streamID) }
        }
    }

    func getProfile(for pubkey: String) -> Profile? {
        return nostrClient.getProfile(for: pubkey)
    }

    private func updateCategorizedStreams() {
        // Update all streams (unfiltered)
        self.allCategorizedStreams = categorizeStreams(streams)

        // Filter streams by follow list if not empty
        let filteredStreams: [Stream]
        if !followList.isEmpty {
            filteredStreams = streams.filter { stream in
                guard let pubkey = stream.pubkey else { return false }
                return followList.contains(pubkey)
            }
        } else {
            // If follow list is empty, show all streams
            filteredStreams = streams
        }

        // Update filtered streams
        self.categorizedStreams = categorizeStreams(filteredStreams)
    }

    private func categorizeStreams(_ streamList: [Stream]) -> [StreamCategory] {
        // Separate live and ended streams
        let liveStreams = streamList.filter { $0.isLive }
        let endedStreams = streamList.filter { !$0.isLive }

        // Group live streams by category
        let liveStreamsByCategory = Dictionary(grouping: liveStreams) { $0.category }

        // Create categories for live streams, sorted alphabetically
        var categories: [StreamCategory] = []

        for (categoryName, categoryStreams) in liveStreamsByCategory.sorted(by: { $0.key < $1.key }) {
            let sortedStreams = categoryStreams.sorted { stream1, stream2 in
                // Sort by creation date (newest first), then by title
                if let date1 = stream1.createdAt, let date2 = stream2.createdAt {
                    return date1 > date2
                }
                return stream1.title < stream2.title
            }
            categories.append(StreamCategory(name: categoryName, streams: sortedStreams))
        }

        // Add past streams category at the bottom if there are any
        if !endedStreams.isEmpty {
            let sortedEndedStreams = endedStreams.sorted { stream1, stream2 in
                // Sort ended streams by creation date (newest first)
                if let date1 = stream1.createdAt, let date2 = stream2.createdAt {
                    return date1 > date2
                }
                return stream1.title < stream2.title
            }
            categories.append(StreamCategory(name: "Past Streams", streams: sortedEndedStreams))
        }

        return categories
    }

    private func validateStreamURL(_ stream: Stream) {
        // Skip if already validating this stream
        guard !validationTasks.contains(stream.streamID) else { return }

        // Skip if URL is a placeholder for ended streams
        guard !stream.streaming_url.hasPrefix("ended://") else { return }

        guard let url = URL(string: stream.streaming_url) else {
            removeInvalidStream(stream)
            return
        }

        validationTasks.insert(stream.streamID)
        // Validating stream (removed verbose logging)

        // Use AVAsset to validate if the URL is actually a playable stream
        Task {
            let asset = AVAsset(url: url)

            do {
                // Try to load the asset's playable property with timeout
                let isPlayable = try await withTimeout(seconds: 15) {
                    try await asset.load(.isPlayable)
                }

                await MainActor.run {
                    self.validationTasks.remove(stream.streamID)
                    if !isPlayable {
                        // Stream not playable (removed verbose logging)
                        self.removeInvalidStream(stream)
                    }
                    // Stream validated (removed verbose logging)
                }
            } catch {
                await MainActor.run {
                    self.validationTasks.remove(stream.streamID)
                    // Stream validation failed (removed verbose logging)
                    self.removeInvalidStream(stream)
                }
            }
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func removeInvalidStream(_ stream: Stream) {
        streams.removeAll { $0.streamID == stream.streamID }
        updateCategorizedStreams()
    }
}
