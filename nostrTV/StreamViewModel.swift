import Foundation

struct StreamCategory {
    let name: String
    let streams: [Stream]
}

class StreamViewModel: ObservableObject {
    @Published var streams: [Stream] = []
    @Published var categorizedStreams: [StreamCategory] = []
    private var nostrClient = NostrClient()
    private var refreshTimer: Timer?

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
            }
        }

        startAutoRefresh()
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
        // Separate live and ended streams
        let liveStreams = streams.filter { $0.isLive }
        let endedStreams = streams.filter { !$0.isLive }

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
}
