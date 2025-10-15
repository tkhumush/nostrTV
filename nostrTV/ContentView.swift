//
//  ContentView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins

struct FeaturedStreamCardView: View {
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
            VStack(alignment: .leading, spacing: 12) {
                // Large thumbnail with live indicator overlay
                ZStack(alignment: .topLeading) {
                    // Thumbnail
                    if let imageURL = stream.imageURL, let url = URL(string: imageURL) {
                        CachedAsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 400)
                                .clipped()
                                .cornerRadius(12)
                        } placeholder: {
                            Color.gray.frame(height: 400)
                                .cornerRadius(12)
                        }
                    } else if let pubkey = stream.pubkey,
                              let profile = viewModel.getProfile(for: pubkey),
                              let pictureURL = profile.picture,
                              let url = URL(string: pictureURL) {
                        CachedAsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 400)
                                .clipped()
                                .cornerRadius(12)
                        } placeholder: {
                            Color.gray.frame(height: 400)
                                .cornerRadius(12)
                        }
                    } else {
                        Color.gray.frame(height: 400)
                            .cornerRadius(12)
                    }

                    // Live indicator badge (top left with padding)
                    if stream.isLive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text("LIVE")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(6)
                        .padding(16)
                    }
                }

                // Stream info
                VStack(alignment: .leading, spacing: 8) {
                    // Stream title
                    Text(stream.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    // Streamer info
                    HStack(spacing: 8) {
                        // Profile picture
                        if let pubkey = stream.pubkey,
                           let profile = viewModel.getProfile(for: pubkey),
                           let pictureURL = profile.picture,
                           let url = URL(string: pictureURL) {
                            CachedAsyncImage(url: url) { image in
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

                        // Username
                        Text({
                            if let pubkey = stream.pubkey,
                               let profile = viewModel.getProfile(for: pubkey) {
                                return profile.displayNameOrName
                            }
                            return "Unknown"
                        }())
                        .font(.body)
                        .foregroundColor(.secondary)
                    }

                    // Category and viewer count
                    HStack(spacing: 12) {
                        Text(stream.category)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)

                        if stream.viewerCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "eye.fill")
                                    .font(.caption)
                                Text("\(stream.viewerCount)")
                                    .font(.subheadline)
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

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

struct StreamListView: View {
    @ObservedObject var viewModel: StreamViewModel
    let categorizedStreams: [StreamCategory]
    let featuredStream: Stream?
    let onStreamSelected: (URL, String?, Stream) -> Void

    var body: some View {
        List {
            // Featured stream section (stream with most viewers)
            if let featured = featuredStream {
                Section {
                    FeaturedStreamCardView(stream: featured, viewModel: viewModel) { url, lightningAddress, selectedStream in
                        onStreamSelected(url, lightningAddress, selectedStream)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            // Regular categorized streams
            ForEach(categorizedStreams, id: \.name) { category in
                Section(header: CategoryHeaderView(categoryName: category.name, streamCount: category.streams.count)) {
                    ForEach(category.streams) { stream in
                        // Don't show the featured stream again in the regular list
                        if stream.id != featuredStream?.id {
                            StreamRowView(stream: stream, viewModel: viewModel) { url, lightningAddress, selectedStream in
                                onStreamSelected(url, lightningAddress, selectedStream)
                            }
                        }
                    }
                }
            }
        }
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
        ZStack(alignment: .topTrailing) {
            TabView {
                // Following tab
                NavigationView {
                    StreamListView(
                        viewModel: viewModel,
                        categorizedStreams: viewModel.categorizedStreams,
                        featuredStream: viewModel.featuredStream
                    ) { url, lightningAddress, selectedStream in
                        let player = AVPlayer(url: url)
                        self.player = player
                        self.selectedLightningAddress = lightningAddress
                        self.selectedStream = selectedStream
                        self.showPlayer = true
                    }
                    .navigationTitle("Following")
                }
                .tabItem {
                    Label("Following", systemImage: "person.2.fill")
                }

                // Discover tab (all streams)
                NavigationView {
                    StreamListView(
                        viewModel: viewModel,
                        categorizedStreams: viewModel.allCategorizedStreams,
                        featuredStream: viewModel.streams.filter { $0.isLive }.max(by: { $0.viewerCount < $1.viewerCount })
                    ) { url, lightningAddress, selectedStream in
                        let player = AVPlayer(url: url)
                        self.player = player
                        self.selectedLightningAddress = lightningAddress
                        self.selectedStream = selectedStream
                        self.showPlayer = true
                    }
                    .navigationTitle("Discover")
                }
                .tabItem {
                    Label("Discover", systemImage: "globe")
                }
            }

            // Profile button overlayed on top right
            Button(action: {
                showProfilePage = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 32))
                    Image(systemName: "gear")
                        .font(.system(size: 20))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 60)
            .padding(.trailing, 40)
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
