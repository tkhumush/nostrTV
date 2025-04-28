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
    @State private var player: AVPlayer?

    var body: some View {
        NavigationView {
            List(viewModel.streams) { stream in
                Button(action: {
                    if let url = URL(string: stream.streaming_url) {
                        let player = AVPlayer(url: url)
                        self.player = player
                        self.showPlayer = true
                    }
                }) {
                    HStack(spacing: 12) {
                        if let imageURL = stream.imageURL, let url = URL(string: imageURL) {
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 200, height: 120)
                                    .clipped()
                                    .cornerRadius(8)
                            } placeholder: {
                                Color.gray.frame(width: 200, height: 120)
                                    .cornerRadius(8)
                            }
                        } else {
                            Color.gray.frame(width: 200, height: 120)
                                .cornerRadius(8)
                        }

                        Text(stream.title)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Live Streams")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        viewModel.refreshStreams()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $showPlayer) {
            if let player = player {
                VideoPlayerView(player: player)
            }
        }
        .onChange(of: showPlayer) { oldValue, newValue in
            if oldValue == true && newValue == false {
                player?.pause()
                player = nil
            }
        }
    }
}
