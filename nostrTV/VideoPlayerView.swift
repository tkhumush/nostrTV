import SwiftUI
import AVKit
import Combine

struct VideoPlayerView: View {
    let player: AVPlayer
    let lightningAddress: String?
    let stream: Stream?
    let nostrSDKClient: NostrSDKClient
    @ObservedObject var authManager: NostrAuthManager
    @StateObject private var activityManager = StreamActivityManager()
    @StateObject private var playback: CovePlaybackObserver
    @State private var liveActivityManager: LiveActivityManager?
    @State private var presenceTimer: Timer?
    @State private var joinTask: Task<Void, Never>?
    @State private var chatMessage = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var showLogin = false
    @State private var isChatVisible: Bool
    @State private var surface: Surface = .controls
    @State private var returnFocus: Control = .pause
    @FocusState private var focusedControl: Control?
    @Namespace private var controlsNamespace
    @Environment(\.dismiss) private var dismiss
    enum Surface { case controls, cinema, creator, zap, playbackOptions }
    enum Control: Hashable { case back, creator, pause, chat, zap, cinema, cinemaSurface, options, message, send, login }

    init(player: AVPlayer, lightningAddress: String?, stream: Stream?, nostrSDKClient: NostrSDKClient, authManager: NostrAuthManager) {
        self.player = player
        self.lightningAddress = lightningAddress
        self.stream = stream
        self.nostrSDKClient = nostrSDKClient
        self.authManager = authManager
        _playback = StateObject(wrappedValue: CovePlaybackObserver(player: player))
        _isChatVisible = State(initialValue: UserDefaults.standard.object(forKey: "cove.showChat") as? Bool ?? true)
    }

    private var panelIsOpen: Bool { surface == .creator || surface == .zap }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                HStack(spacing: 0) {
                    ZStack {
                        // This player remains at the same structural identity as panels and chat change.
                        VideoPlayerContainer(player: player, showsControls: surface == .playbackOptions) {
                            returnFocus = .options
                            surface = .controls
                        }
                        .allowsHitTesting(surface == .playbackOptions)
                        .accessibilityHidden(surface != .playbackOptions)
                        if surface == .cinema {
                            Button { revealControls() } label: { Color.black.opacity(0.001).contentShape(Rectangle()) }
                                .buttonStyle(CinemaSurfaceStyle())
                                .focused($focusedControl, equals: .cinemaSurface)
                                .focusEffectDisabled()
                                .accessibilityLabel("Show player controls")
                                .accessibilityIdentifier("cinema-surface")
                                .onMoveCommand { _ in revealControls() }
                                .onExitCommand { revealControls() }
                                .onAppear { focusedControl = .cinemaSurface }
                        } else if surface != .playbackOptions {
                            playerChrome
                                .task(id: isChatVisible) {
                                    // Wait for the newly inserted controls to join the focus tree.
                                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                                    guard surface == .controls else { return }
                                    focusedControl = returnFocus
                                }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if isChatVisible && surface != .cinema && surface != .playbackOptions, let stream {
                        chatRail(stream: stream)
                            .frame(width: min(520, max(400, geometry.size.width * 0.26)))
                    }
                }
                .disabled(panelIsOpen)
                .focusScope(controlsNamespace)
                if panelIsOpen, let stream {
                    StreamerProfilePopupView(stream: stream, authManager: authManager,
                        nostrSDKClient: nostrSDKClient, onDismiss: closePanel, startsWithZap: surface == .zap)
                        .zIndex(2)
                }
            }
        }
        .background(.black).foregroundStyle(.white).ignoresSafeArea()
        .onExitCommand {
            if panelIsOpen { closePanel() }
            else if surface == .cinema { revealControls() }
            else if surface == .playbackOptions { returnFocus = .options; surface = .controls }
            else { dismiss() }
        }
        .onPlayPauseCommand { togglePlayback() }
        .fullScreenCover(isPresented: $showLogin) { WelcomeView(authManager: authManager) }
        .onChange(of: authManager.isAuthenticated) { _, authenticated in if authenticated { showLogin = false } }
        .onAppear { startActivity() }
        .onDisappear {
            joinTask?.cancel()
            activityManager.stopListening()
            presenceTimer?.invalidate(); presenceTimer = nil
            if let manager = liveActivityManager { Task { try? await manager.leaveCurrentStream() } }
            liveActivityManager = nil
        }
    }

    private var playerChrome: some View {
        ZStack {
            VStack {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom).frame(height: 380)
            }.allowsHitTesting(false)
            VStack(alignment: .leading) {
                HStack {
                    Button { dismiss() } label: { Label("Browse", systemImage: "chevron.left") }
                        .buttonStyle(CoveButtonStyle()).focused($focusedControl, equals: .back)
                        .accessibilityIdentifier("player-back")
                    Spacer()
                    CoveLiveBadge(live: stream?.isLive ?? true)
                    if let stream { Text("\(stream.viewerCount) watching").font(.coveCaption).foregroundStyle(Color.coveSecondary) }
                }.focusSection()
                Spacer()
                if playback.isBuffering && !playback.failed {
                    HStack(spacing: 16) { ProgressView().tint(.coveAccent); Text("Connecting to the stream…").font(.coveBody) }
                }
                if playback.failed {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This stream couldn’t be played.").font(.coveSubheading)
                        Text("Return to Browse and try another stream.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                    }
                }
                Text("YOU’RE WATCHING").font(.system(size: 16, weight: .bold)).tracking(3).foregroundStyle(Color.coveAccent).padding(.top, 18)
                Text(stream?.title ?? "Live stream").font(.system(size: 38, weight: .semibold, design: .rounded)).lineLimit(2)
                if let stream {
                    Button { openPanel(.creator, from: .creator) } label: {
                        HStack(spacing: 14) {
                            CoveAvatar(profile: stream.profile, size: 38)
                            Text(stream.profile?.displayNameOrName ?? "Meet the creator").lineLimit(1)
                            Image(systemName: "chevron.right").font(.coveSmall)
                        }
                    }.buttonStyle(CoveButtonStyle()).focused($focusedControl, equals: .creator)
                        .accessibilityIdentifier("player-creator")
                }
                Rectangle().fill(.white.opacity(0.15)).frame(height: 1).padding(.vertical, 14)
                HStack(spacing: 18) {
                    Button(action: togglePlayback) { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                        .buttonStyle(CoveButtonStyle()).focused($focusedControl, equals: .pause)
                        .prefersDefaultFocus(in: controlsNamespace)
                        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                    Spacer(minLength: 5)
                    if stream != nil {
                        Button { returnFocus = .chat; isChatVisible.toggle() } label: { Label(isChatVisible ? "Hide chat" : "Show chat", systemImage: "bubble.left") }
                            .buttonStyle(CoveButtonStyle()).focused($focusedControl, equals: .chat)
                            .accessibilityIdentifier("player-chat")
                        Button { openPanel(.zap, from: .zap) } label: { Label("Send a zap", systemImage: "bolt.fill") }
                            .buttonStyle(CoveButtonStyle(prominent: true)).focused($focusedControl, equals: .zap)
                            .accessibilityIdentifier("player-zap")
                    }
                    Button {
                        surface = .cinema
                    } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(CoveButtonStyle()).focused($focusedControl, equals: .cinema)
                        .accessibilityLabel("Cinema mode").accessibilityIdentifier("player-cinema")
                    Button { surface = .playbackOptions } label: { Image(systemName: "ellipsis") }
                        .buttonStyle(CoveButtonStyle()).focused($focusedControl, equals: .options)
                        .accessibilityLabel("Playback options").accessibilityHint("Open native playback, seeking, audio, and subtitle controls")
                }.focusSection()
            }.padding(45)
        }
    }

    private func chatRail(stream: Stream) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("In good company").font(.system(size: 28, weight: .semibold, design: .rounded))
                Label("Live chat", systemImage: "circle.fill").font(.system(size: 18)).foregroundStyle(Color.coveGold)
            }.padding(30).padding(.top, 25)
            Divider().overlay(Color.coveOverlay)
            LiveChatView(activityManager: activityManager, stream: stream, nostrClient: nostrSDKClient)
            Divider().overlay(Color.coveOverlay)
            VStack(alignment: .leading, spacing: 16) {
                if authManager.isAuthenticated {
                    Text("Join the conversation").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                    HStack(spacing: 12) {
                        TextField("Say hello…", text: $chatMessage)
                            .font(.coveCaption).focused($focusedControl, equals: .message)
                            .submitLabel(.send).onSubmit(sendChatMessage)
                            .accessibilityIdentifier("chat-message")
                        Button(action: sendChatMessage) { Image(systemName: "arrow.up") }
                            .buttonStyle(CoveButtonStyle(prominent: true))
                            .disabled(isSending || chatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .focused($focusedControl, equals: .send).accessibilityLabel("Send message")
                    }
                    if isSending { Text("Sending…").font(.coveSmall).foregroundStyle(Color.coveSecondary) }
                    if let sendError { Text(sendError).font(.coveSmall).foregroundStyle(Color.coveGold) }
                } else {
                    Text("Sign in to join the conversation.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                    Button("Sign in") { showLogin = true }
                        .buttonStyle(CoveButtonStyle()).focused($focusedControl, equals: .login)
                }
            }.padding(30).padding(.bottom, 15).focusSection()
        }.background(Color.coveSurface)
    }

    private func togglePlayback() { playback.isPlaying ? player.pause() : player.play() }
    private func openPanel(_ next: Surface, from control: Control) { returnFocus = control; surface = next }
    private func closePanel() { surface = .controls; focusedControl = returnFocus }
    private func revealControls() { returnFocus = .cinema; surface = .controls }

    private func startActivity() {
        #if DEBUG
        if CoveUITestSupport.enabled { focusedControl = .pause; return }
        #endif
        guard liveActivityManager == nil else { return }
        let manager = LiveActivityManager(nostrSDKClient: nostrSDKClient, authManager: authManager)
        liveActivityManager = manager
        if let stream {
            activityManager.startListening(for: stream, using: nostrSDKClient)
            joinTask = Task { try? await manager.joinStreamWithConnection(stream) }
        }
        if case .bunker = authManager.authMethod {
            presenceTimer?.invalidate()
            presenceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { try? await manager.updatePresence() }
            }
        }
        player.play()
        focusedControl = .pause
    }

    private func sendChatMessage() {
        let text = chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, authManager.isAuthenticated, let manager = liveActivityManager else { return }
        isSending = true; sendError = nil
        Task { @MainActor in
            do {
                try await manager.sendChatMessage(text)
                // The relay subscription supplies the signed message; avoid a duplicate temporary echo.
                if chatMessage.trimmingCharacters(in: .whitespacesAndNewlines) == text { chatMessage = "" }
                focusedControl = .chat
            } catch {
                sendError = "Message wasn’t sent. Please try again."
            }
            isSending = false
        }
    }
}

/// Even `.plain` paints a focus highlight on tvOS. This remote target must
/// receive Select/Back/directional input without adding anything over the movie.
private struct CinemaSurfaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Keep playback state in sync with remote commands and AVPlayer buffering.
private final class CovePlaybackObserver: ObservableObject {
    @Published var isPlaying = true
    @Published var isBuffering = false
    @Published var failed = false
    private var subscriptions = Set<AnyCancellable>()
    init(player: AVPlayer) {
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] status in
            self?.isPlaying = status != .paused
            self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
        }.store(in: &subscriptions)
        player.currentItem?.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            self?.failed = status == .failed
        }.store(in: &subscriptions)
    }
}

/// Render video without a second set of native focus targets competing with Cove's controls.
struct VideoPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let showsControls: Bool
    let onBack: () -> Void
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = CoveAVPlayerController()
        controller.onBack = onBack
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.view.isUserInteractionEnabled = false
        UIApplication.shared.isIdleTimerDisabled = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        (controller as? CoveAVPlayerController)?.onBack = onBack
        controller.view.isUserInteractionEnabled = showsControls
        if controller.showsPlaybackControls != showsControls {
            controller.showsPlaybackControls = showsControls
            if showsControls { controller.setNeedsFocusUpdate(); controller.updateFocusIfNeeded() }
        }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

private final class CoveAVPlayerController: AVPlayerViewController {
    var onBack: (() -> Void)?
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onBack?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
