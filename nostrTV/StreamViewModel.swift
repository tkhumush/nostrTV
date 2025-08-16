import Foundation

class StreamViewModel: ObservableObject {
    @Published var streams: [Stream] = []
    private var nostrClient = NostrClient()

    init() {
        nostrClient.onStreamReceived = { [weak self] stream in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Avoid duplicates by streamID
                if !self.streams.contains(where: { $0.streamID == stream.streamID }) {
                    self.streams.append(stream)
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
        nostrClient.disconnect()
        nostrClient.connect()
    }
    
    func getProfile(for pubkey: String) -> Profile? {
        return nostrClient.getProfile(for: pubkey)
    }
}
