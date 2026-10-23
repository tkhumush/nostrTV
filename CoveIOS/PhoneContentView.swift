import SwiftUI

struct PhoneContentView: View {
    let client: NostrSDKClient
    @StateObject private var streams: StreamViewModel
    @EnvironmentObject private var auth: NostrAuthManager

    init(client: NostrSDKClient) {
        self.client = client
        _streams = StateObject(wrappedValue: StreamViewModel(nostrSDKClient: client))
    }

    var body: some View {
        TabView {
            NavigationStack {
                PhoneStreamList(viewModel: streams, client: client, following: false)
                    .navigationTitle("Discover")
            }
            .tabItem { Label("Discover", systemImage: "play.rectangle") }

            NavigationStack {
                if auth.isAuthenticated {
                    PhoneStreamList(viewModel: streams, client: client, following: true)
                        .navigationTitle("Following")
                } else {
                    PhoneAccountView().navigationTitle("Following")
                }
            }
            .tabItem { Label("Following", systemImage: "person.2") }

            NavigationStack {
                PhoneAccountView().navigationTitle("Your space")
            }
            .tabItem { Label("Your space", systemImage: "person.crop.circle") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(.tabBar)
        .onChange(of: auth.followList, initial: true) { _, list in
            streams.updateFollowList(list)
        }
    }
}

private struct PhoneStreamList: View {
    @ObservedObject var viewModel: StreamViewModel
    let client: NostrSDKClient
    let following: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedStream: Stream?
    @State private var playbackError: String?
    @State private var order = CoveStreamOrder()
    @State private var search = ""
    @State private var category = "All"
    @State private var contentWidth: CGFloat = 0

    private var columns: [GridItem] {
        // Even columns give the inner display two balanced halves as it folds.
        // The minimum is a readable card width, not a device-size breakpoint.
        let fitting = max(1, Int((max(0, contentWidth - 32) + 20) / 260))
        let count = typeSize.isAccessibilitySize ? 1 : fitting > 1 ? fitting - fitting % 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: count)
    }

    private var available: [Stream] {
        (following ? viewModel.categorizedStreams : viewModel.allCategorizedStreams)
            .flatMap(\.streams)
            .filter { $0.isLive || $0.recording?.isEmpty == false }
    }

    private var ordered: [Stream] {
        let lookup = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.ids.compactMap { lookup[$0] }.filter { stream in
            let profile = stream.pubkey.flatMap { viewModel.getProfile(for: $0) } ?? stream.profile
            return (category == "All" || stream.category == category) &&
                (search.isEmpty || stream.title.localizedCaseInsensitiveContains(search) ||
                 (profile?.displayNameOrName.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        ScrollView {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(["All"] + Array(Set(available.map(\.category))).sorted(), id: \.self) { name in
                        Button(name) { category = name }.buttonStyle(.bordered)
                            .tint(name == category ? .coveAccent : .coveSecondary)
                            .accessibilityAddTraits(name == category ? .isSelected : [])
                    }
                }.padding(.horizontal)
            }.scrollIndicators(.hidden)
            if let error = client.initError {
                ContentUnavailableView("Connection unavailable", systemImage: "wifi.exclamationmark",
                                       description: Text(error.localizedDescription))
            } else if viewModel.isInitialLoad && !following {
                ProgressView("Finding streams…").padding(.top, 80)
            } else if ordered.isEmpty {
                ContentUnavailableView(!search.isEmpty || category != "All" ? "No matching streams" : following ? "Nobody you follow is live" : "It’s quiet here for now",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("New broadcasts will appear here as they arrive."))
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(ordered) { stream in
                        let profile = stream.pubkey.flatMap { viewModel.getProfile(for: $0) } ?? stream.profile
                        Button {
                            let source = stream.isLive ? stream.streaming_url : (stream.recording ?? stream.streaming_url)
                            if StreamPlayback.nativeURL(source) != nil {
                                selectedStream = stream.attachingProfile(profile)
                            } else {
                                playbackError = StreamPlayback.unavailableMessage(for: source)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                CoveArtwork(urls: stream.artworkURLs(profile: profile), streamID: stream.id)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .overlay(alignment: .topLeading) {
                                        Text(stream.isLive ? "LIVE" : "REPLAY")
                                            .font(.caption.bold()).padding(8)
                                            .background(.black.opacity(0.7), in: Capsule()).padding(10)
                                    }
                                HStack(alignment: .top, spacing: 12) {
                                    CoveAvatar(profile: profile, size: 36)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(stream.title).font(.headline).lineLimit(2)
                                        Text(profile?.displayNameOrName ?? "Independent creator")
                                            .font(.subheadline).foregroundStyle(Color.coveSecondary)
                                        Text(stream.isLive ? "\(stream.viewerCount.formatted()) watching · \(stream.category)" : stream.category)
                                            .font(.caption).foregroundStyle(Color.coveSecondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("phone-stream-\(stream.streamID)")
                    }
                }.padding()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .background(Color.coveBackground)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .toolbar, prompt: "Streams and creators")
        .modifier(PhoneCompactSearch())
        .onChange(of: available.map(\.id), initial: true) { _, ids in order.reconcile(ids) }
        .onChange(of: available.map(\.category)) { _, names in
            if category != "All" && !names.contains(category) { category = "All" }
        }
        .fullScreenCover(item: $selectedStream) { stream in
            PhoneWatchView(stream: stream, client: client)
        }
        .alert("Stream unavailable", isPresented: Binding(
            get: { playbackError != nil }, set: { if !$0 { playbackError = nil } }
        )) {
            Button("OK", role: .cancel) { playbackError = nil }
        } message: { Text(playbackError ?? "") }
    }
}

/// Keep search in the system toolbar so it joins Duo's vertical controls.
/// The field expands only when requested, retaining native cancel and dictation.
private struct PhoneCompactSearch: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .searchToolbarBehavior(.minimize)
                .modifier(PhoneDuoSearchPlacement())
        } else if #available(iOS 26.0, *) {
            content.searchToolbarBehavior(.minimize)
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct PhoneDuoSearchPlacement: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    func body(content: Content) -> some View {
        content.toolbar {
            // Horizontal bottom toolbars can be displaced by the tab bar.
            // Keep search reachable in open portrait, while sharing the native
            // vertical bar with navigation when the system offers that edge.
            DefaultToolbarItem(kind: .search, placement: verticalEdge == nil ? .topBarTrailing : .bottomBar)
        }
    }
}

private struct PhoneAccountView: View {
    @EnvironmentObject private var auth: NostrAuthManager
    @State private var showSignIn = false
    @State private var confirmSignOut = false
    @AppStorage("cove.showChat") private var showChat = true

    var body: some View {
        List {
            if auth.isAuthenticated {
                Section {
                    HStack(spacing: 16) {
                        CoveAvatar(profile: auth.currentProfile, size: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(auth.currentProfile?.displayNameOrName ?? "Your Nostr identity").font(.headline)
                            Text("Following \(auth.followList.count) people").foregroundStyle(.secondary)
                        }
                    }
                    if let about = auth.currentProfile?.about, !about.isEmpty { Text(about) }
                }
                Section {
                    Button("Refresh profile and follows") { auth.fetchUserData(force: true) }
                        .disabled(auth.isLoadingProfile)
                    if auth.isLoadingProfile { ProgressView("Updating…") }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
            } else {
                Section {
                    Text("Bring your people with you").font(.title2.bold())
                    Text("Connect your Nostr identity to load your follows and join live chat.")
                        .foregroundStyle(.secondary)
                    Button("Sign in with a remote signer") { showSignIn = true }
                        .accessibilityIdentifier("phone-sign-in")
                }
            }
            if let error = auth.errorMessage {
                Section { Text(error).foregroundStyle(Color.coveGold) }
            }
            Section("While you watch") {
                Toggle("Show chat when a stream opens", isOn: $showChat)
                    .accessibilityIdentifier("phone-preference-chat")
                Text("Use the player’s chat button to change this while watching. Video and chat adapt as you open, close, or turn your iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.coveBackground)
        .sheet(isPresented: $showSignIn) { PhoneSignInView() }
        .confirmationDialog("Sign out of Cove?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { auth.logout() }
        }
    }
}
