import SwiftUI

struct PhoneWatchView: View {
    @EnvironmentObject private var auth: NostrAuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("cove.showChat") private var showChat = true
    @StateObject private var session: PhoneWatchSession
    @State private var sheet: Sheet?
    @State private var viewportSize: CGSize = .zero
    @State private var controlsEdge: HorizontalEdge?
    @State private var leadingInset: CGFloat = 0
    enum Sheet: String, Identifiable { case creator, zap, signIn; var id: String { rawValue } }

    init(stream: Stream, client: NostrSDKClient) {
        _session = StateObject(wrappedValue: PhoneWatchSession(stream: stream, client: client))
    }

    var body: some View {
        NavigationStack {
            // The inner reader may extend under the vertical bar, so measure the
            // bar's inset here, where the safe area still applies.
            GeometryReader { safeBounds in
                GeometryReader { geometry in
                    // The keyboard reduces content height without changing portrait
                    // into landscape. Use this presentation's window for arrangement
                    // and the available content bounds for the player/composer sizes.
                    let arrangement = PhoneLayout.watchArrangement(size: viewportSize == .zero ? geometry.size : viewportSize, accessibilityText: typeSize.isAccessibilitySize)
                    let split = arrangement == .sideBySide && showChat
                    // Beside the system's vertical bar, chat runs underneath it so the
                    // picture gets that width. Keep the header and a raised composer clear.
                    let controlsInset = chatUnderControls ? safeBounds.safeAreaInsets.trailing : 0
                    let keyboardRaised = viewportSize.height > 0 && geometry.size.height < viewportSize.height * 0.75
                    let mediaSize = CGSize(width: geometry.size.width - (split ? PhoneLayout.chatWidth(in: geometry.size) : 0), height: geometry.size.height)
                    let layout = split ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        media(size: mediaSize, split: split)
                            .frame(maxWidth: .infinity, maxHeight: showChat && !split ? nil : .infinity, alignment: .top)
                        if showChat {
                            PhoneChatView(session: session, controlsInset: controlsInset, keyboardRaised: keyboardRaised, onSignIn: { sheet = .signIn })
                                .frame(width: split ? PhoneLayout.chatWidth(in: geometry.size) : nil)
                                .frame(maxWidth: split ? nil : .infinity, maxHeight: .infinity)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("phone-watch-\(split ? "sideBySide" : "stacked")")
                    .background {
                        PhoneViewportReader { viewportSize = $0 }
                            .allowsHitTesting(false).accessibilityHidden(true)
                        PhoneToolbarEdgeReader(edge: $controlsEdge)
                        Color.clear
                            .onAppear { leadingInset = safeBounds.safeAreaInsets.leading }
                            .onChange(of: safeBounds.safeAreaInsets.leading) { _, value in leadingInset = value }
                    }
                }
                // Let the picture extend to the top edge; the system still owns
                // safe areas for its navigation controls, camera and vertical bar.
                .ignoresSafeArea(.container, edges: chatUnderControls ? [.top, .trailing] : .top)
            }
            .background(Color.coveBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .accessibilityIdentifier("phone-close-player")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showChat.toggle() } label: {
                        Label(showChat ? "Hide chat" : "Show chat", systemImage: showChat ? "bubble.left.fill" : "bubble.left")
                    }.accessibilityIdentifier("phone-toggle-chat")
                    Button { sheet = .zap } label: { Label("Send a zap", systemImage: "bolt.fill") }
                        .accessibilityIdentifier("phone-zap")
                }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .creator: PhoneCreatorView(stream: session.stream.attachingProfile(session.profile), client: session.client)
            case .zap: PhoneZapView(stream: session.stream.attachingProfile(session.profile), client: session.client)
            case .signIn: PhoneSignInView()
            }
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            // A fold can temporarily deactivate the scene. Never restart or pause for that.
            if phase == .active {
                #if DEBUG
                if CoveUITestSupport.enabled { return }
                #endif
                session.client.connect()
            }
        }
    }

    /// Only the system's trailing vertical bar is covered; a sensor housing never is.
    /// Landscape iPhones inset both sides for the Dynamic Island, so require a clear leading edge.
    private var chatUnderControls: Bool {
        showChat && controlsEdge == .trailing && leadingInset < 1 && viewportSize != .zero &&
            PhoneLayout.watchArrangement(size: viewportSize, accessibilityText: typeSize.isAccessibilitySize) == .sideBySide
    }

    private func media(size: CGSize, split: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PhoneNativePlayer(session: session)
                if session.buffering { ProgressView().allowsHitTesting(false) }
                if session.failed {
                    VStack(spacing: 12) {
                        Label("The stream could not play", systemImage: "exclamationmark.triangle")
                        Button("Try again") { session.retry() }.buttonStyle(.borderedProminent)
                    }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(height: split ? PhoneLayout.splitVideoHeight(in: size, accessibilityText: typeSize.isAccessibilitySize) : PhoneLayout.videoHeight(in: size, showingChat: showChat, accessibilityText: typeSize.isAccessibilitySize))
            .accessibilityElement(children: .contain).accessibilityIdentifier("phone-video")
            Button { sheet = .creator } label: {
                HStack(alignment: .top, spacing: 12) {
                    CoveAvatar(profile: session.profile, size: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.stream.title).font(.headline).lineLimit(size.height < 420 ? 1 : typeSize.isAccessibilitySize ? 2 : 3)
                        Text(session.profile?.displayNameOrName ?? "Independent creator")
                            .font(.subheadline).foregroundStyle(Color.coveSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.coveSecondary)
                }.padding().contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("phone-creator")
            // Beside chat (or with chat hidden) the column has room to spare below the creator.
            if split || !showChat {
                PhoneStreamStatsView(stats: session.stats, stream: session.stream, onZap: { sheet = .zap })
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            #if DEBUG
            if CoveUITestSupport.enabled {
                PhonePlaybackProbe(session: session)
            }
            #endif
        }
    }
}

/// Reports which edge holds the system's vertical toolbar, or nil with horizontal bars.
private struct PhoneToolbarEdgeReader: View {
    @Binding var edge: HorizontalEdge?
    var body: some View {
        if #available(iOS 27.1, *) { Reader(edge: $edge) } else { Color.clear }
    }
    @available(iOS 27.1, *)
    private struct Reader: View {
        @Environment(\.toolbarVerticalEdge) private var verticalEdge
        @Binding var edge: HorizontalEdge?
        var body: some View {
            Color.clear
                .onAppear { edge = verticalEdge }
                .onChange(of: verticalEdge) { _, value in edge = value }
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// Reads the current presentation window, including during folds and rotation.
/// Unlike main-screen bounds, these bounds follow the app's actual window; they
/// also remain stable when the keyboard consumes part of the content safe area.
private struct PhoneViewportReader: UIViewRepresentable {
    let onChange: (CGSize) -> Void
    func makeUIView(context: Context) -> ViewportView {
        let view = ViewportView()
        view.onChange = onChange
        return view
    }
    func updateUIView(_ view: ViewportView, context: Context) {
        view.onChange = onChange
        view.reportSize()
    }
    final class ViewportView: UIView {
        var onChange: ((CGSize) -> Void)?
        private var reportedSize: CGSize = .zero
        override func didMoveToWindow() { super.didMoveToWindow(); reportSize() }
        override func layoutSubviews() { super.layoutSubviews(); reportSize() }
        func reportSize() {
            guard let size = window?.bounds.size, size != .zero, size != reportedSize else { return }
            reportedSize = size
            DispatchQueue.main.async { [weak self] in self?.onChange?(size) }
        }
    }
}
