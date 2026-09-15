//
//  VideoPlayerView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins

/// Main video player view with integrated zap button and chyron
struct VideoPlayerView: View {
    let player: AVPlayer
    let lightningAddress: String?
    let stream: Stream?
    let nostrSDKClient: NostrSDKClient
    let authManager: NostrAuthManager

    @State private var presenceTimer: Timer?
    @State private var liveActivityManager: LiveActivityManager?
    @StateObject private var activityManager: StreamActivityManager
    @State private var chatMessage = ""
    @State private var isChatVisible = true  // Track chat visibility
    @Environment(\.dismiss) private var dismiss

    /// Which surface currently owns the screen.
    ///
    /// Previously the overlays were independent booleans with nothing stopping both
    /// from being true, which would render two overlays as ZStack siblings competing
    /// for focus. A single enum makes the states mutually exclusive by construction.
    enum ActiveSurface: Hashable {
        case chrome
        case sideMenu
    }

    @State private var activeSurface: ActiveSurface = .chrome

    // Focus management for tvOS
    @FocusState private var focusedField: FocusableField?
    @Namespace private var focusNamespace

    /// Controls in the player chrome. Overlays deliberately keep their own focus
    /// state and namespace instead of extending this enum, so each surface owns a
    /// self-contained focus scope.
    enum FocusableField: Hashable {
        case profileButton
        case toggleChatButton
        case textField
        case sendButton
        case cancelButton
    }

    init(player: AVPlayer, lightningAddress: String?, stream: Stream?, nostrSDKClient: NostrSDKClient, authManager: NostrAuthManager) {
        self.player = player
        self.lightningAddress = lightningAddress
        self.stream = stream
        self.nostrSDKClient = nostrSDKClient
        self.authManager = authManager

        // Create StreamActivityManager for combined chat + zaps subscription
        _activityManager = StateObject(wrappedValue: StreamActivityManager())
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Row 1: Banner (83%) and Chat toggle (17%)
                if let stream = stream {
                    HStack(spacing: 0) {
                        // Banner section (83%)
                        HStack(spacing: 16) {
                            // Cove logo
                            Text("Cove")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(.coveAccent)

                            Text("|")
                                .font(.system(size: 26))
                                .foregroundColor(.coveSecondary.opacity(0.6))

                            // Stream info: profile pic + username + stream name + viewer count (clickable)
                            Button(action: { activeSurface = .sideMenu }) {
                                HStack(spacing: 12) {
                                    // Profile picture
                                    if let profile = stream.profile, let pictureURL = profile.picture, let url = URL(string: pictureURL) {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 52, height: 52)
                                                    .clipShape(Circle())
                                            case .failure(_), .empty:
                                                Circle()
                                                    .fill(Color.coveOverlay)
                                                    .frame(width: 52, height: 52)
                                            @unknown default:
                                                Circle()
                                                    .fill(Color.coveOverlay)
                                                    .frame(width: 52, height: 52)
                                            }
                                        }
                                    } else {
                                        Circle()
                                            .fill(Color.coveOverlay)
                                            .frame(width: 52, height: 52)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        // Username
                                        Text(stream.profile?.displayName ?? stream.profile?.name ?? "Anonymous")
                                            .font(.system(size: 22, weight: .semibold))
                                            .foregroundColor(.white)

                                        // Stream name
                                        Text(stream.title)
                                            .font(.system(size: 18))
                                            .foregroundColor(.white.opacity(0.7))
                                            .lineLimit(1)
                                    }

                                    // Viewer count badge
                                    HStack(spacing: 6) {
                                        Image(systemName: "eye.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.white.opacity(0.8))

                                        Text("\(stream.viewerCount)")
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.card)
                            .focused($focusedField, equals: .profileButton)
                            // Pairs with the .onAppear assignment: states the intended
                            // landing point declaratively rather than relying on the
                            // focus engine's geometry heuristics.
                            .prefersDefaultFocus(in: focusNamespace)

                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                        .focusSection()

                        // Chat controls (17%)
                        HStack(spacing: 8) {
                            Spacer()
                            ToggleChatButton(
                                isChatVisible: $isChatVisible,
                                action: { isChatVisible.toggle() }
                            )
                                .focused($focusedField, equals: .toggleChatButton)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 23)
                        .frame(width: 375)
                        .background(.ultraThinMaterial)
                        .focusSection()
                    }
                }

                // Row 2: Video player (83%) and Live chat (17%)
                HStack(spacing: 0) {
                    // Video player (83%)
                    VideoPlayerContainer(
                        player: player,
                        stream: stream,
                        // SwiftUI's `.disabled` does not cross into a UIKit controller,
                        // so the player is told separately to stop taking focus.
                        isInteractive: activeSurface == .chrome,
                        onDismiss: { dismiss() },
                        shouldHandleMenuPress: {
                            // Close the topmost surface rather than the player. Only
                            // when nothing is layered above the chrome does Menu mean
                            // "leave the stream".
                            guard activeSurface != .chrome else { return false }
                            activeSurface = .chrome
                            return true
                        }
                    )
                    .frame(maxWidth: .infinity)

                    // Live chat column (17%)
                    //
                    // Rendered conditionally rather than collapsed to zero width and
                    // opacity. allowsHitTesting(false) stops taps but does not remove a
                    // view from the tvOS focus engine's candidate list, so the previous
                    // approach let focus move invisibly into a hidden chat column.
                    if isChatVisible, let stream = stream {
                        LiveChatView(
                            activityManager: activityManager,
                            stream: stream,
                            nostrClient: nostrSDKClient
                        )
                        .frame(width: 375)
                        .background(Color.coveBackground)
                    }
                }

                // Row 3: Zap chyron (83%) and Comment button (17%)
                HStack(spacing: 0) {
                    // Zap chyron (83%)
                    if let stream = stream {
                        ZapChyronWrapper(activityManager: activityManager, stream: stream, nostrSDKClient: nostrSDKClient)
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer()
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                    }

                    // Chat input (17% - fixed width, always visible)
                    if let stream = stream {
                        ChatInputView(
                            message: $chatMessage,
                            focusedField: $focusedField,
                            onSend: {
                                sendChatMessage()
                            },
                            onDismiss: {
                                chatMessage = ""
                                // Cancel previously cleared the text and left focus
                                // wherever it was, with no defined landing point.
                                focusedField = .toggleChatButton
                            }
                        )
                        .padding(.horizontal, 0)
                        .padding(.vertical, 16)
                        .frame(width: 375)  // Match chat column width
                    }
                }
                .background(.ultraThinMaterial)
                .focusSection()
            }  // Close VStack wrapper for banner + content
            // Scope the chrome so `prefersDefaultFocus(in:)` resolves against it.
            //
            // Note this does NOT keep focus inside the chrome — `focusScope` only
            // scopes default-focus preferences, it is not a barrier. Keeping an
            // overlay's focus out is the job of `.disabled` below.
            .focusScope(focusNamespace)
            // While an overlay is up, take the entire chrome out of the focus engine.
            //
            // Nothing softer works: opacity, `allowsHitTesting`, `contentShape`, and
            // `zIndex` all leave a view focusable, so the Siri Remote kept landing on
            // the chrome and the player transport instead of the overlay on top.
            // `.disabled` is the modifier that actually removes focus candidacy.
            .disabled(activeSurface != .chrome)

            // Streamer profile side menu
            if activeSurface == .sideMenu, let stream = stream {
                StreamerProfilePopupView(
                    stream: stream,
                    authManager: authManager,
                    nostrSDKClient: nostrSDKClient,
                    onDismiss: { activeSurface = .chrome }
                )
                // Menu/Back returns to the player rather than leaving the stream.
                //
                // `shouldHandleMenuPress` on the player controller cannot cover this:
                // once focus is inside this overlay the press never reaches that
                // controller, it goes to the SwiftUI hosting controller, which
                // dismisses the whole player. `onExitCommand` is the tvOS hook that
                // fires while focus is within this view.
                .onExitCommand { activeSurface = .chrome }
                .animation(.easeInOut(duration: 0.3), value: activeSurface)
                .zIndex(999)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // Initialize LiveActivityManager with authManager for signing
            liveActivityManager = LiveActivityManager(nostrSDKClient: nostrSDKClient, authManager: authManager)

            // Join the stream
            if let stream = stream, let activityManager = liveActivityManager {
                Task {
                    do {
                        try await activityManager.joinStreamWithConnection(stream)
                    } catch {
                        print("❌ Error joining stream: \(error)")
                    }
                }
            }

            // Start listening for chat and zaps (combined subscription)
            if let stream = stream {
                // Do NOT stop first. onAppear fires repeatedly while the player is open,
                // and an unconditional stop/start cycle destroyed the live subscription
                // and cleared the message buffers every time — chat never accumulated.
                // startListening is idempotent: it no-ops when already listening to this
                // stream and tears down the old subscription only when switching streams.
                activityManager.startListening(for: stream, using: nostrSDKClient)
            }

            // Start presence updates for bunker-authenticated users
            if authManager.authMethod != nil, case .bunker = authManager.authMethod {
                startPresenceTimer()
            }

            // Set default focus after layout settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedField = .profileButton
            }
        }
        .onChange(of: isChatVisible) { oldValue, newValue in
            // Restore focus when chat visibility changes
            if !newValue {
                // Chat hidden - move focus to toggle button
                focusedField = .toggleChatButton
            }
        }
        .onChange(of: activeSurface) { oldValue, newValue in
            // Restore focus to the chrome when an overlay closes.
            //
            // The delay matters: the side menu animates out over 0.3s, and assigning
            // focus while it is still present can fail outright or bounce focus back
            // into the disappearing overlay.
            guard newValue == .chrome, oldValue != .chrome else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focusedField = .profileButton
            }
        }
        .onDisappear {
            // Stop the combined chat+zaps subscription
            activityManager.stopListening()

            // Leave the stream (live activity presence)
            if let liveManager = liveActivityManager {
                Task {
                    do {
                        try await liveManager.leaveCurrentStream()
                    } catch {
                        print("❌ Error leaving stream: \(error)")
                    }
                }
            }

            // Stop presence timer
            presenceTimer?.invalidate()
            presenceTimer = nil
        }
    }

    private func startPresenceTimer() {
        // Update presence every 60 seconds for bunker-authenticated users
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [self] _ in
            guard let activityManager = liveActivityManager else { return }
            Task {
                do {
                    try await activityManager.updatePresence()
                } catch {
                    print("⚠️ Failed to update presence: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendChatMessage() {
        guard !chatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        guard let stream = stream else {
            return
        }

        guard let liveActivityManager = liveActivityManager else {
            return
        }

        guard authManager.isAuthenticated else {
            print("❌ User not authenticated - cannot send chat message")
            return
        }

        let messageText = chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        // Optimistic self-echo: immediately show the message in chat
        if let userPubkey = authManager.currentUser?.hexPubkey {
            let localMessage = ChatMessage(
                id: UUID().uuidString,  // Temporary ID until relay echoes back
                senderPubkey: userPubkey,
                message: messageText,
                timestamp: Date()
            )
            activityManager.addLocalMessage(localMessage)
        }

        // Clear input immediately for responsive feel
        chatMessage = ""

        // Park focus somewhere known. Leaving it on the text field re-raises the tvOS
        // keyboard, and leaving it unset lets the focus engine pick by geometry.
        focusedField = .toggleChatButton

        Task {
            do {
                try await liveActivityManager.sendChatMessage(messageText)
            } catch {
                print("❌ Failed to send chat message: \(error)")
            }
        }
    }
}

/// Container for the AVPlayerViewController
struct VideoPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let stream: Stream?

    /// False while an overlay owns the screen. AVPlayerViewController shows transport
    /// controls by default and is the strongest focus magnet on screen, so it has to be
    /// stood down explicitly or it wins focus over anything layered above it.
    let isInteractive: Bool

    let onDismiss: () -> Void

    /// Returns true if a Menu press was consumed by an overlay rather than meaning
    /// "dismiss the player".
    let shouldHandleMenuPress: () -> Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = CustomAVPlayerViewController()
        controller.player = player
        controller.stream = stream
        controller.onDismiss = onDismiss
        controller.shouldHandleMenuPress = shouldHandleMenuPress
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Rebind so the closure always sees current SwiftUI state rather than the
        // values captured when the controller was first created.
        (uiViewController as? CustomAVPlayerViewController)?.shouldHandleMenuPress = shouldHandleMenuPress

        // The transport controls are the player's only focusable content, so hiding
        // them is what takes it out of the focus engine. Playback is unaffected.
        //
        // Deliberately NOT setting `view.isUserInteractionEnabled = false` here: this
        // controller is also what routes Menu presses to `shouldHandleMenuPress`, and
        // a view that cannot take interaction may stop receiving them — which would
        // break closing the overlay with Menu, the case that matters most.
        uiViewController.showsPlaybackControls = isInteractive
    }
}

// Custom controller that disables the idle timer
class CustomAVPlayerViewController: AVPlayerViewController {
    var stream: Stream?  // Stream being watched (for reference)
    var onDismiss: (() -> Void)?  // Closure to dismiss the view

    /// Asked first on every Menu/Back press. Return true when SwiftUI handled it —
    /// for example by closing an overlay — so the press is not treated as "dismiss
    /// the player". Only when this returns false does the whole player go away.
    var shouldHandleMenuPress: (() -> Bool)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true

        // Note: LiveActivityManager is now handled by VideoPlayerView.onAppear
        // which has access to authManager for proper bunker authentication support
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false

        // Note: LiveActivityManager cleanup is handled by VideoPlayerView.onDisappear
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Offer the press to SwiftUI first. Previously this unconditionally dismissed
        // the player, so pressing Menu with the side menu open tore down the whole
        // player instead of just closing the overlay.
        for press in presses where press.type == .menu {
            if shouldHandleMenuPress?() == true {
                return  // Consumed by an overlay
            }
            onDismiss?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

// Wrapper view to observe activityManager and pass zap comments to the chyron
struct ZapChyronWrapper: View {
    @ObservedObject var activityManager: StreamActivityManager
    let stream: Stream
    let nostrSDKClient: NostrSDKClient

    var body: some View {
        // Force update when activity changes
        let _ = activityManager.updateTrigger

        // Get zaps from the activity manager
        let zaps = activityManager.zapComments

        return ZapChyronView(zapComments: zaps, nostrSDKClient: nostrSDKClient, activityManager: activityManager)
    }
}

/// Chat input view for sending messages
struct ChatInputView: View {
    @Binding var message: String
    @FocusState.Binding var focusedField: VideoPlayerView.FocusableField?
    let onSend: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            // Text field
            TextField(CoveCopy.chatPlaceholder, text: $message)
                .font(.system(size: 18))
                .padding(.horizontal, 12)
                .foregroundColor(.white)
                .focused($focusedField, equals: .textField)
                .frame(width: 241, height: 58)
                // Let the tvOS keyboard send directly. Without this the only way to
                // post was to dismiss the keyboard and navigate to the send button.
                .submitLabel(.send)
                .onSubmit {
                    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onSend()
                }

            // Send button
            ChatActionButton(
                icon: "paperplane.fill",
                color: .coveAccent,
                action: onSend
            )
            .focused($focusedField, equals: .sendButton)

            // Cancel button - icon only
            ChatActionButton(
                icon: "xmark",
                color: .red,
                action: onDismiss
            )
            .focused($focusedField, equals: .cancelButton)
        }
        .padding(.horizontal, 0)
    }
}

/// Chat action button with icon and Liquid Glass style
private struct ChatActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
        }
        .buttonStyle(.card)
        .tint(color)
    }
}

/// Type message button with native Liquid Glass style
private struct TypeMessageButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 19))
                    .foregroundColor(.purple)
                Text("Comment")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.card)
    }
}

/// Toggle chat visibility button
private struct ToggleChatButton: View {
    @Binding var isChatVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isChatVisible ? "eye.slash.fill" : "eye.fill")
                .font(.system(size: 22))
                .foregroundColor(isChatVisible ? .coveGold : .coveAccent)
                .frame(width: 58, height: 58)
        }
        .buttonStyle(.card)
    }
}
