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
                        // Stream thumbnail
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
                        
                        // Stream info including profile
                        VStack(alignment: .leading, spacing: 8) {
                            Text(stream.title)
                                .font(.headline)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            
                            // Profile info
                            HStack(spacing: 6) {
                                // Profile picture
                                if let pubkey = stream.pubkey,
                                   let profile = viewModel.getProfile(for: pubkey),
                                   let pictureURL = profile.picture,
                                   let url = URL(string: pictureURL) {
                                    AsyncImage(url: url) { image in
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 24, height: 24)
                                            .clipShape(Circle())
                                    } placeholder: {
                                        Circle()
                                            .fill(Color.gray)
                                            .frame(width: 24, height: 24)
                                    }
                                } else {
                                    // Default profile picture
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Image(systemName: "person.fill")
                                                .foregroundColor(.white)
                                                .font(.system(size: 12))
                                        )
                                }
                                
                                // Username
                                Text({
                                    if let pubkey = stream.pubkey,
                                       let profile = viewModel.getProfile(for: pubkey) {
                                        return profile.displayNameOrName
                                    }
                                    return "Unknown"
                                }())
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
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
            .onAppear {
                viewModel.refreshStreams()
            }
        }
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $showPlayer) {
            if let player = player {
                VideoPlayerView(player: player)
                    .ignoresSafeArea()
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
