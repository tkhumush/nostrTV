import Foundation
import AVFoundation

struct StreamCategory {
    let name: String
    let streams: [Stream]
}

class StreamViewModel: ObservableObject {
    @Published var streams: [Stream] = []
    @Published var categorizedStreams: [StreamCategory] = []
    private var nostrClient = NostrClient()
    private var refreshTimer: Timer?
    private var followList: [String] = []
    private var validationTasks: Set<String> = [] // Track ongoing validations

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

    func getProfile(for pubkey: String) -> Profile? {
        return nostrClient.getProfile(for: pubkey)
    }

    private func updateCategorizedStreams() {
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

        // Separate live and ended streams
        let liveStreams = filteredStreams.filter { $0.isLive }
        let endedStreams = filteredStreams.filter { !$0.isLive }

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

        self.categorizedStreams = categories
    }

    private func validateStreamURL(_ stream: Stream) {
        // Skip if already validating this stream
        guard !validationTasks.contains(stream.streamID) else { return }

        // Skip if URL is a placeholder for ended streams
        guard !stream.streaming_url.hasPrefix("ended://") else { return }

        guard let url = URL(string: stream.streaming_url) else {
            print("⚠️ Invalid stream URL: \(stream.streaming_url)")
            removeInvalidStream(stream)
            return
        }

        validationTasks.insert(stream.streamID)
        print("🔍 Validating stream: \(stream.title) - URL: \(stream.streaming_url)")

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
                        print("❌ Stream not playable: \(stream.title)")
                        self.removeInvalidStream(stream)
                    } else {
                        print("✅ Stream validated as playable: \(stream.title)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.validationTasks.remove(stream.streamID)
                    print("❌ Stream validation failed: \(stream.title) - \(error.localizedDescription)")
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
