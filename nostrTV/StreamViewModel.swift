//
//  StreamViewModel.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

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
}
