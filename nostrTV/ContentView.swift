//
//  ContentView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject var viewModel = StreamViewModel()
    @State private var selectedStreamURL: URL?
    @State private var showPlayer = false

    var body: some View {
        NavigationView {
            List(viewModel.streams) { stream in
                Button(action: {
                    if let url = URL(string: stream.streaming_url) {
                        selectedStreamURL = url
                        showPlayer = true
                    }
                }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(stream.title)
                            .font(.title3)
                        Text(stream.streaming_url)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Live Streams")
        }
        .sheet(isPresented: $showPlayer) {
            if let url = selectedStreamURL {
                VideoPlayerView(url: url)
            }
        }
    }
}
