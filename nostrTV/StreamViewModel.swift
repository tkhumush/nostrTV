import Foundation

struct StreamCategory {
    let name: String
    let streams: [Stream]
}

class StreamViewModel: ObservableObject {
    @Published var streams: [Stream] = []
    @Published var categorizedStreams: [StreamCategory] = []
    private var nostrClient = NostrClient()

    init() {
        nostrClient.onStreamReceived = { [weak self] stream in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Avoid duplicates by streamID
                if !self.streams.contains(where: { $0.streamID == stream.streamID }) {
                    self.streams.append(stream)
                    self.updateCategorizedStreams()
                }
            }
        }

        nostrClient.connect()
    }

    deinit {
        nostrClient.disconnect()
    }

    func refreshStreams() {
        streams.removeAll()
        categorizedStreams.removeAll()
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
