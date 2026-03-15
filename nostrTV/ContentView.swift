//
//  ContentView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins

/// Loading view for Curated tab when admin follow list is being fetched
struct CuratedLoadingView: View {
    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            ProgressView()
                .scaleEffect(2)
                .tint(.coveAccent)

            Text(CoveCopy.appLoading)
                .font(.coveSubheading)
                .foregroundColor(.white)

            Text(CoveCopy.loadingSubtitle)
                .font(.coveBody)
                .foregroundColor(.coveSecondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.coveBackground)
    }
}

/// Empty state view for Following tab when user is not logged in
struct FollowingEmptyStateView: View {
    let onLoginTap: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "person.2.fill")
                .font(.system(size: 100))
                .foregroundColor(.coveAccent.opacity(0.6))

            Text(CoveCopy.loginPrompt)
                .font(.coveSubheading)
                .foregroundColor(.white)

            Text(CoveCopy.loginSubtitle)
                .font(.coveBody)
                .foregroundColor(.coveSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Log In", action: onLoginTap)
                .buttonStyle(.borderedProminent)
                .tint(.coveAccent)
                .font(.coveSubheading)
                .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.coveBackground)
    }
}

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
                            Image("Top Shelf Image")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 400)
                                .clipped()
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
                            Image("Top Shelf Image")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 400)
                                .clipped()
                                .cornerRadius(12)
                        }
                    } else {
                        Image("Top Shelf Image")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 400)
                            .clipped()
                            .cornerRadius(12)
                    }

                    // Live indicator badge — warm amber glow
                    if stream.isLive {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.coveGold)
                                .frame(width: 10, height: 10)
                                .shadow(color: .coveGold.opacity(0.8), radius: 4)
                            Text("LIVE")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.coveBackground.opacity(0.85))
                        .cornerRadius(CoveUI.badgeCornerRadius)
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
                                    .fill(Color.coveOverlay)
                                    .frame(width: 32, height: 32)
                            }
                        } else {
                            Circle()
                                .fill(Color.coveAccent.opacity(0.3))
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
                        .foregroundColor(.coveSecondary)
                    }

                    // Category and viewer count
                    HStack(spacing: 12) {
                        Text(stream.category)
                            .font(.subheadline)
                            .foregroundColor(.coveSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.coveOverlay)
                            .cornerRadius(CoveUI.badgeCornerRadius)

                        if stream.viewerCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "eye.fill")
                                    .font(.caption)
                                Text("\(stream.viewerCount)")
                                    .font(.subheadline)
                            }
                            .foregroundColor(.coveSecondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.card)
    }
}

struct CategoryHeaderView: View {
    let categoryName: String
    let streamCount: Int

    var body: some View {
        HStack {
            Text(categoryName)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Spacer()
            Text("\(streamCount)")
                .font(.caption)
                .foregroundColor(.coveSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.coveOverlay)
                .cornerRadius(CoveUI.badgeCornerRadius)
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
                        Image("Top Shelf Image")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 200, height: 120)
                            .clipped()
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
                        Image("Top Shelf Image")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 200, height: 120)
                            .clipped()
                            .cornerRadius(8)
                    }
                } else {
                    Image("Top Shelf Image")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 120)
                        .clipped()
                        .cornerRadius(8)
                }

                // Stream info including profile
                VStack(alignment: .leading, spacing: 8) {
                    Text(stream.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Status indicator and tags
                    HStack(spacing: 8) {
                        // Live/Ended indicator — amber glow for live
                        HStack(spacing: 4) {
                            Circle()
                                .fill(stream.isLive ? Color.coveGold : Color.coveSecondary)
                                .frame(width: 8, height: 8)
                                .shadow(color: stream.isLive ? .coveGold.opacity(0.6) : .clear, radius: 3)
                            Text(stream.isLive ? "LIVE" : "ENDED")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(stream.isLive ? .coveGold : .coveSecondary)
                        }

                        // Tags
                        if !stream.tags.isEmpty {
                            Text(stream.tags.prefix(2).joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.coveSecondary)
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
                                    .fill(Color.coveOverlay)
                                    .frame(width: 24, height: 24)
                            }
                        } else {
                            // Default profile picture
                            Circle()
                                .fill(Color.coveAccent.opacity(0.3))
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
                        .foregroundColor(.coveSecondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .buttonStyle(.card)
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
    @EnvironmentObject var authManager: NostrAuthManager
    @State private var selectedStreamURL: URL?
    @State private var showPlayer = false
    @State private var player: AVPlayer?
    @State private var selectedLightningAddress: String?
    @State private var selectedStream: Stream?  // Track selected stream for live activity
    @State private var showProfilePage = false
    @State private var showLoginSheet = false

    init() {
        let vm = StreamViewModel()
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView {
                // Curated tab (filtered by admin follow list)
                NavigationView {
                    if viewModel.isInitialLoad {
                        CuratedLoadingView()
                    } else {
                        StreamListView(
                            viewModel: viewModel,
                            categorizedStreams: viewModel.allCategorizedStreams,
                            featuredStream: viewModel.discoverFeaturedStream
                        ) { url, lightningAddress, selectedStream in
                            let player = AVPlayer(url: url)
                            self.player = player
                            self.selectedLightningAddress = lightningAddress

                            // Attach profile to stream before passing to VideoPlayerView
                            var streamWithProfile = selectedStream
                            if let pubkey = selectedStream.pubkey, let profile = viewModel.getProfile(for: pubkey) {
                                streamWithProfile = Stream(
                                    streamID: selectedStream.streamID,
                                    eventID: selectedStream.eventID,
                                    title: selectedStream.title,
                                    streaming_url: selectedStream.streaming_url,
                                    imageURL: selectedStream.imageURL,
                                    pubkey: selectedStream.pubkey,
                                    eventAuthorPubkey: selectedStream.eventAuthorPubkey,
                                    profile: profile,
                                    status: selectedStream.status,
                                    tags: selectedStream.tags,
                                    createdAt: selectedStream.createdAt,
                                    viewerCount: selectedStream.viewerCount,
                                    recording: selectedStream.recording,
                                    startsAt: selectedStream.startsAt
                                )
                            }

                            self.selectedStream = streamWithProfile
                            self.showPlayer = true
                        }
                    }
                }
                .tabItem {
                    Label("Curated", systemImage: "star.fill")
                }

                // Following tab
                NavigationView {
                    if authManager.isAuthenticated {
                        StreamListView(
                            viewModel: viewModel,
                            categorizedStreams: viewModel.categorizedStreams,
                            featuredStream: viewModel.featuredStream
                        ) { url, lightningAddress, selectedStream in
                            let player = AVPlayer(url: url)
                            self.player = player
                            self.selectedLightningAddress = lightningAddress

                            // Attach profile to stream before passing to VideoPlayerView
                            var streamWithProfile = selectedStream
                            if let pubkey = selectedStream.pubkey, let profile = viewModel.getProfile(for: pubkey) {
                                streamWithProfile = Stream(
                                    streamID: selectedStream.streamID,
                                    eventID: selectedStream.eventID,
                                    title: selectedStream.title,
                                    streaming_url: selectedStream.streaming_url,
                                    imageURL: selectedStream.imageURL,
                                    pubkey: selectedStream.pubkey,
                                    eventAuthorPubkey: selectedStream.eventAuthorPubkey,
                                    profile: profile,
                                    status: selectedStream.status,
                                    tags: selectedStream.tags,
                                    createdAt: selectedStream.createdAt,
                                    viewerCount: selectedStream.viewerCount,
                                    recording: selectedStream.recording,
                                    startsAt: selectedStream.startsAt
                                )
                            }

                            self.selectedStream = streamWithProfile
                            self.showPlayer = true
                        }
                    } else {
                        FollowingEmptyStateView(onLoginTap: {
                            showLoginSheet = true
                        })
                    }
                }
                .tabItem {
                    Label("Following", systemImage: "person.2.fill")
                }
            }

            // Profile button overlayed on top right
            Button(action: {
                showProfilePage = true
            }) {
                // Show actual profile picture if logged in, otherwise generic icon
                if authManager.isAuthenticated, let profile = authManager.currentProfile, let pictureURL = profile.picture {
                    AsyncImage(url: URL(string: pictureURL)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(Circle())
                    } placeholder: {
                        Circle()
                            .fill(Color.coveOverlay)
                            .frame(width: 48, height: 48)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.coveAccent)
                            )
                    }
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 48))
                }
            }
            .buttonStyle(.card)
            .padding(.top, 60)
            .padding(.trailing, 40)
        }
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $showPlayer) {
            if let player = player {
                VideoPlayerView(player: player, lightningAddress: selectedLightningAddress, stream: selectedStream, nostrSDKClient: viewModel.sdkClient, authManager: authManager)
                    .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showProfilePage) {
            ProfileSettingsView(authManager: authManager, isPresented: $showProfilePage)
        }
        .fullScreenCover(isPresented: $showLoginSheet) {
            LoginFlowView(authManager: authManager)
        }
        .onAppear {
            // Update follow list when view appears
            viewModel.updateFollowList(authManager.followList)
        }
        .onChange(of: authManager.followList) { oldValue, newValue in
            // Update filter when follow list changes
            viewModel.updateFollowList(newValue)
        }
        .onChange(of: authManager.isAuthenticated) { oldValue, newValue in
            // Close login sheet when user successfully authenticates
            if newValue == true {
                showLoginSheet = false
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
