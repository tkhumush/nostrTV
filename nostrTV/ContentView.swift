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
    let onStreamSelected: (URL, String?, Stream) -> Void

    var body: some View {
        Button(action: {
            if let url = URL(string: stream.streaming_url) {
                let lightningAddress: String? = {
                    if let pubkey = stream.pubkey, let profile = viewModel.getProfile(for: pubkey) {
                        return profile.lud16
                    }
                    return nil
                }()
                onStreamSelected(url, lightningAddress, stream)
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
        .opacity(stream.isLive ? 1.0 : 0.6) // Dim ended streams
    }
}

struct ContentView: View {
    @StateObject private var viewModel: StreamViewModel
    @StateObject private var zapManager: ZapManager
    @EnvironmentObject var authManager: NostrAuthManager
    @State private var selectedStreamURL: URL?
    @State private var showPlayer = false
    @State private var player: AVPlayer?
    @State private var selectedLightningAddress: String?
    @State private var selectedStream: Stream?  // Track selected stream for live activity
    @State private var showProfilePage = false

    init() {
        let vm = StreamViewModel()
        _viewModel = StateObject(wrappedValue: vm)
        _zapManager = StateObject(wrappedValue: ZapManager(nostrClient: vm.client))
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.categorizedStreams, id: \.name) { category in
                    Section(header: CategoryHeaderView(categoryName: category.name, streamCount: category.streams.count)) {
                        ForEach(category.streams) { stream in
                            StreamRowView(stream: stream, viewModel: viewModel) { url, lightningAddress, selectedStream in
                                let player = AVPlayer(url: url)
                                self.player = player
                                self.selectedLightningAddress = lightningAddress
                                self.selectedStream = selectedStream
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
                            // Standard user profile icon
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 32))
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
                VideoPlayerView(player: player, lightningAddress: selectedLightningAddress, stream: selectedStream, nostrClient: viewModel.client, zapManager: zapManager, authManager: authManager)
                    .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showProfilePage) {
            ProfileSettingsView(authManager: authManager, isPresented: $showProfilePage)
        }
        .onAppear {
            // Update follow list when view appears
            viewModel.updateFollowList(authManager.followList)
        }
        .onChange(of: authManager.followList) { oldValue, newValue in
            // Update filter when follow list changes
            viewModel.updateFollowList(newValue)
        }
        .onChange(of: showPlayer) { oldValue, newValue in
            if oldValue == true && newValue == false {
                player?.pause()
                player = nil
            }
        }
    }
}
