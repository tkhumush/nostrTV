//
//  ContentView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins

struct CategoryHeaderView: View {
    let categoryName: String
    let streamCount: Int

    var body: some View {
        HStack {
            Text(categoryName)
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
            Text("\(streamCount)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
        }
        .padding(.vertical, 4)
    }
}

struct StreamRowView: View {
    let stream: Stream
    let viewModel: StreamViewModel
    let onStreamSelected: (URL, String?) -> Void

    var body: some View {
        Button(action: {
            // Only allow playback for live streams
            guard stream.isLive else { return }

            if let url = URL(string: stream.streaming_url) {
                let lightningAddress: String? = {
                    if let pubkey = stream.pubkey, let profile = viewModel.getProfile(for: pubkey) {
                        return profile.lud16
                    }
                    return nil
                }()
                onStreamSelected(url, lightningAddress)
            }
        }) {
            HStack(spacing: 12) {
                // Stream thumbnail with profile picture fallback
                if let imageURL = stream.imageURL, let url = URL(string: imageURL) {
                    CachedAsyncImage(url: url) { image in
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
                } else if let pubkey = stream.pubkey,
                          let profile = viewModel.getProfile(for: pubkey),
                          let pictureURL = profile.picture,
                          let url = URL(string: pictureURL) {
                    // Use profile picture as fallback thumbnail
                    CachedAsyncImage(url: url) { image in
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

                    // Status indicator and tags
                    HStack(spacing: 8) {
                        // Live/Ended indicator
                        HStack(spacing: 4) {
                            Circle()
                                .fill(stream.isLive ? Color.red : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(stream.isLive ? "LIVE" : "ENDED")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(stream.isLive ? .red : .gray)
                        }

                        // Tags
                        if !stream.tags.isEmpty {
                            Text(stream.tags.prefix(2).joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Profile info
                    HStack(spacing: 6) {
                        // Profile picture
                        if let pubkey = stream.pubkey,
                           let profile = viewModel.getProfile(for: pubkey),
                           let pictureURL = profile.picture,
                           let url = URL(string: pictureURL) {
                            CachedAsyncImage(url: url) { image in
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

                Spacer()
            }
        }
        .disabled(!stream.isLive) // Disable button for ended streams
        .opacity(stream.isLive ? 1.0 : 0.6) // Dim ended streams
    }
}

struct ContentView: View {
    @StateObject var viewModel = StreamViewModel()
    @EnvironmentObject var authManager: NostrAuthManager
    @State private var selectedStreamURL: URL?
    @State private var showPlayer = false
    @State private var player: AVPlayer?
    @State private var selectedLightningAddress: String?
    @State private var showProfilePage = false

    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.categorizedStreams, id: \.name) { category in
                    Section(header: CategoryHeaderView(categoryName: category.name, streamCount: category.streams.count)) {
                        ForEach(category.streams) { stream in
                            StreamRowView(stream: stream, viewModel: viewModel) { url, lightningAddress in
                                let player = AVPlayer(url: url)
                                self.player = player
                                self.selectedLightningAddress = lightningAddress
                                print("Selected Lightning Address: \(self.selectedLightningAddress ?? "nil")")
                                self.showPlayer = true
                            }
                        }
                    }
                }
            }
            .navigationTitle("Live Streams")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showProfilePage = true
                    }) {
                        HStack(spacing: 8) {
                            // Profile picture
                            if let pictureURL = authManager.currentProfile?.picture,
                               let url = URL(string: pictureURL) {
                                AsyncImage(url: url) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 32, height: 32)
                                        .clipShape(Circle())
                                } placeholder: {
                                    Circle()
                                        .fill(Color.gray)
                                        .frame(width: 32, height: 32)
                                }
                            } else {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "person.fill")
                                            .foregroundColor(.white)
                                            .font(.system(size: 16))
                                    )
                            }
                            Image(systemName: "gear")
                                .font(.system(size: 20))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $showPlayer) {
            if let player = player {
                VideoPlayerView(player: player, lightningAddress: selectedLightningAddress)
                    .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showProfilePage) {
            ProfileSettingsView(authManager: authManager, isPresented: $showProfilePage)
        }
        .onChange(of: showPlayer) { oldValue, newValue in
            if oldValue == true && newValue == false {
                player?.pause()
                player = nil
            }
        }
    }
}
