import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var viewModel: StreamViewModel
    @EnvironmentObject private var authManager: NostrAuthManager
    @State private var page: Page = .discover
    @State private var player: AVPlayer?
    @State private var selectedStream: Stream?
    @State private var showPlayer = false
    @State private var showLoginSheet = false
    @State private var showProfilePage = true
    private let nostrSDKClient: NostrSDKClient
    enum Page: String, CaseIterable { case discover = "Discover", following = "Following", profile = "Your space" }

    init(nostrSDKClient: NostrSDKClient) {
        self.nostrSDKClient = nostrSDKClient
        _viewModel = StateObject(wrappedValue: StreamViewModel(nostrSDKClient: nostrSDKClient))
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            ZStack {
                // Keep each shelf alive when switching tabs so its order and focus survive.
                StreamListView(viewModel: viewModel, categories: viewModel.allCategorizedStreams,
                               isFollowing: false, isLoading: viewModel.isInitialLoad,
                               onStreamSelected: watch)
                    .opacity(page == .discover ? 1 : 0).disabled(page != .discover)
                    .accessibilityHidden(page != .discover)
                if authManager.isAuthenticated {
                    StreamListView(viewModel: viewModel, categories: viewModel.categorizedStreams,
                                   isFollowing: true, isLoading: false, onStreamSelected: watch)
                        .opacity(page == .following ? 1 : 0).disabled(page != .following)
                        .accessibilityHidden(page != .following)
                } else if page == .following {
                    VStack(alignment: .leading, spacing: 35) {
                        CoveEmptyState(symbol: "person.2", title: "Your people are here.", message: "Connect your Nostr identity to bring your follow list with you. You can always browse and watch without signing in.")
                        Button("Sign in") { showLoginSheet = true }.buttonStyle(CoveButtonStyle(prominent: true))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(80)
                }
                if page == .profile {
                    ProfileSettingsView(authManager: authManager, isPresented: $showProfilePage)
                }
            }
        }
        .background(Color.coveBackground).foregroundStyle(.white)
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $showPlayer) {
            if let player {
                VideoPlayerView(player: player, lightningAddress: selectedStream?.profile?.lud16,
                                stream: selectedStream, nostrSDKClient: nostrSDKClient, authManager: authManager)
            }
        }
        .fullScreenCover(isPresented: $showLoginSheet) { WelcomeView(authManager: authManager) }
        .onAppear { viewModel.updateFollowList(authManager.followList) }
        .onChange(of: authManager.followList) { _, list in viewModel.updateFollowList(list) }
        .onChange(of: authManager.isAuthenticated) { _, authenticated in if authenticated { showLoginSheet = false } }
        .onChange(of: showPlayer) { _, showing in
            if !showing { player?.pause(); player = nil }
        }
    }

    private var navigation: some View {
        HStack(spacing: 50) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("cove").font(.system(size: 50, weight: .bold, design: .rounded)).tracking(-3)
                Circle().fill(Color.coveAccent).frame(width: 11, height: 11)
            }.accessibilityLabel("Cove")
            ForEach([Page.discover, .following], id: \.self) { item in
                Button(item.rawValue) { page = item }
                    .buttonStyle(CoveButtonStyle(selected: page == item))
                    .accessibilityIdentifier("nav-\(item == .discover ? "discover" : "following")")
                    .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer()
            Button { page = .profile } label: {
                HStack(spacing: 14) {
                    CoveAvatar(profile: authManager.currentProfile, size: 36)
                    Text(authManager.isAuthenticated ? "Your space" : "Sign in")
                }
            }.buttonStyle(CoveButtonStyle(selected: page == .profile))
                .accessibilityIdentifier("nav-profile")
        }
        .padding(.horizontal, 80).padding(.top, 40).padding(.bottom, 20)
        .focusSection()
    }

    private func watch(_ stream: Stream) {
        guard let url = URL(string: stream.isLive ? stream.streaming_url : (stream.recording ?? stream.streaming_url)) else { return }
        selectedStream = stream.attachingProfile(stream.pubkey.flatMap { viewModel.getProfile(for: $0) })
        #if DEBUG
        player = CoveUITestSupport.enabled ? AVPlayer() : AVPlayer(url: url)
        #else
        player = AVPlayer(url: url)
        #endif
        showPlayer = true
    }
}

struct StreamListView: View {
    @ObservedObject var viewModel: StreamViewModel
    let categories: [StreamCategory]
    let isFollowing: Bool
    let isLoading: Bool
    let onStreamSelected: (Stream) -> Void
    @State private var order = CoveStreamOrder()
    @State private var selectedCategory = "All live"
    @FocusState private var focusedStream: String?

    private var incoming: [Stream] { categories.flatMap(\.streams).filter(\.isLive) }
    private var streams: [Stream] {
        let lookup = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.ids.compactMap { lookup[$0] }
    }
    private var featured: Stream? { streams.first }
    private var recordings: [Stream] { categories.flatMap(\.streams).filter { !$0.isLive && $0.recording?.isEmpty == false } }
    private var categoryNames: [String] { Array(Set(incoming.map(\.category))).sorted() }
    private var shelf: [Stream] {
        streams.filter { ($0.id != featured?.id || selectedCategory != "All live") && (selectedCategory == "All live" || $0.category == selectedCategory) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if isLoading {
                    HStack(spacing: 24) { ProgressView().tint(.coveAccent); Text("Finding your company…").font(.coveSubheading) }
                        .padding(80)
                } else if let featured {
                    FeaturedStreamCardView(stream: featured, profile: profile(for: featured), onWatch: { onStreamSelected(featured) })
                        .focused($focusedStream, equals: featured.id)
                        .id(featured.id)
                    if !shelf.isEmpty || !categoryNames.isEmpty {
                        VStack(alignment: .leading, spacing: 30) {
                            HStack(alignment: .center, spacing: 40) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(isFollowing ? "Live from your people" : "Find your company").font(.system(size: 32, weight: .semibold, design: .rounded))
                                    Text(isFollowing ? "A familiar place to tune in." : "Independent voices. Happening now.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                                }.frame(minWidth: 430, alignment: .leading)
                                Spacer(minLength: 0)
                                ScrollView(.horizontal) {
                                    HStack(spacing: 16) {
                                        ForEach(["All live"] + categoryNames, id: \.self) { name in
                                            Button(name) { selectedCategory = name }
                                                .buttonStyle(CoveButtonStyle(selected: name == selectedCategory))
                                                .accessibilityAddTraits(name == selectedCategory ? .isSelected : [])
                                        }
                                    }.padding(10)
                                }.scrollIndicators(.hidden).focusSection()
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 30), count: 4), alignment: .leading, spacing: 40) {
                                ForEach(shelf) { stream in
                                    StreamRowView(stream: stream, profile: profile(for: stream)) { onStreamSelected(stream) }
                                        .focused($focusedStream, equals: stream.id).id(stream.id)
                                }
                            }.focusSection()
                        }.padding(.horizontal, 80)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 30) {
                        CoveEmptyState(symbol: isFollowing ? "moon.stars" : "antenna.radiowaves.left.and.right",
                            title: emptyTitle, message: emptyMessage)
                    }.padding(80).frame(minHeight: 600, alignment: .leading)
                }
                if !recordings.isEmpty {
                    VStack(alignment: .leading, spacing: 30) {
                        Text("Catch up").font(.coveSubheading)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 30), count: 4), spacing: 40) {
                            ForEach(recordings) { stream in
                                StreamRowView(stream: stream, profile: profile(for: stream)) { onStreamSelected(stream) }
                            }
                        }
                    }.padding(.horizontal, 80).focusSection()
                }
            }
            .padding(.bottom, 70)
        }

        .onChange(of: incoming.map(\.id), initial: true) { _, ids in order.reconcile(ids) }
        .onChange(of: categoryNames) { _, names in
            if selectedCategory != "All live" && !names.contains(selectedCategory) { selectedCategory = "All live" }
        }
    }

    private var emptyTitle: String {
        if !isFollowing { return "It’s quiet here for now." }
        return viewModel.followListCount == 0 ? "Your follow list hasn’t loaded." : "Nobody you follow is live."
    }
    private var emptyMessage: String {
        if !isFollowing { return "No live streams are available yet. We’ll keep listening for new broadcasts. Try Following or check your connection if this continues." }
        return viewModel.followListCount == 0 ? "Open Your space to refresh your profile and follow list, or discover someone new to watch." : "You’re following \(viewModel.followListCount) people. Check Discover for more live streams while they’re away."
    }
    private func profile(for stream: Stream) -> Profile? { stream.pubkey.flatMap { viewModel.getProfile(for: $0) } ?? stream.profile }
}

struct FeaturedStreamCardView: View {
    let stream: Stream
    let profile: Profile?
    let onWatch: () -> Void
    var body: some View {
        ZStack(alignment: .leading) {
            CoveArtwork(url: stream.imageURL ?? profile?.picture)
            LinearGradient(stops: [.init(color: .coveBackground, location: 0), .init(color: .coveBackground.opacity(0.9), location: 0.3), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .coveBackground], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 23) {
                HStack(spacing: 24) {
                    CoveLiveBadge()
                    Text(stream.category.uppercased()).font(.system(size: 18, weight: .semibold)).tracking(3).foregroundStyle(Color.coveAccent)
                }
                Text(stream.title).font(.system(size: 58, weight: .semibold, design: .rounded)).lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: 850, alignment: .leading)
                HStack(spacing: 16) {
                    CoveAvatar(profile: profile)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile?.displayNameOrName ?? "Independent creator").font(.coveBody)
                        Text("\(stream.viewerCount) watching").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                    }
                }
                Button(action: onWatch) { Label("Watch live", systemImage: "play.fill") }
                    .buttonStyle(CoveButtonStyle(prominent: true)).accessibilityIdentifier("watch-featured")
            }.padding(.horizontal, 80).padding(.vertical, 30)
        }.frame(height: 400).clipped()
    }
}

struct StreamRowView: View {
    let stream: Stream
    let profile: Profile?
    let onWatch: () -> Void
    var body: some View {
        Button(action: onWatch) {
            VStack(alignment: .leading, spacing: 18) {
                CoveArtwork(url: stream.imageURL ?? profile?.picture)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .topLeading) { CoveLiveBadge(live: stream.isLive).padding(16).background(Color.coveBackground.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 8)).padding(16) }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                HStack(alignment: .top, spacing: 14) {
                    CoveAvatar(profile: profile, size: 38)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(stream.title).font(.system(size: 26, weight: .semibold)).lineLimit(2).frame(height: 64, alignment: .topLeading)
                        Text(profile?.displayNameOrName ?? "Independent creator").font(.coveCaption).foregroundStyle(Color.coveSecondary).lineLimit(1)
                        Text("\(stream.viewerCount) watching · \(stream.category)").font(.system(size: 18)).foregroundStyle(Color.coveSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }.padding(6)
        }
        .buttonStyle(CoveStreamCardStyle())
        .accessibilityLabel("\(stream.title), by \(profile?.displayNameOrName ?? "Independent creator"), \(stream.viewerCount) watching")
    }
}

private struct CoveStreamCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CoveStreamCardSurface(configuration: configuration) }
}
private struct CoveStreamCardSurface: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        configuration.label.foregroundStyle(.white)
            .padding(10).background(focused ? Color.coveSurface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(focused ? Color.coveAccent : .clear, lineWidth: 4))
            .scaleEffect(focused && !reduceMotion ? 1.025 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
    }
}
