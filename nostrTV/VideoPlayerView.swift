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

    @State private var showZapMenu = false
    @State private var showZapQR = false
    @State private var selectedZapOption: ZapOption?
    @State private var invoiceURI: String?
    @State private var presenceTimer: Timer?
    @State private var liveActivityManager: LiveActivityManager?
    @State private var showStreamerProfile = false
    @StateObject private var activityManager: StreamActivityManager
    @State private var chatMessage = ""
    @State private var isChatVisible = true  // Track chat visibility
    @Environment(\.dismiss) private var dismiss

    // Focus management for tvOS
    @FocusState private var focusedField: FocusableField?
    @Namespace private var focusNamespace

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
                            // nostrTV logo
                            Text("nostrTV")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)

                            Text("|")
                                .font(.system(size: 26))
                                .foregroundColor(.gray.opacity(0.6))

                            // Stream info: profile pic + username + stream name + viewer count (clickable)
                            Button(action: { showStreamerProfile = true }) {
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
                                                    .fill(Color.gray.opacity(0.5))
                                                    .frame(width: 52, height: 52)
                                            @unknown default:
                                                Circle()
                                                    .fill(Color.gray.opacity(0.5))
                                                    .frame(width: 52, height: 52)
                                            }
                                        }
                                    } else {
                                        Circle()
                                            .fill(Color.gray.opacity(0.5))
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
                        onDismiss: { dismiss() }
                    )
                    .frame(maxWidth: .infinity)

                    // Live chat column (17% - always present for focus stability)
                    if let stream = stream {
                        LiveChatView(
                            activityManager: activityManager,
                            stream: stream,
                            nostrClient: nostrSDKClient
                        )
                        .frame(width: isChatVisible ? 375 : 0)  // Collapse width when hidden
                        .opacity(isChatVisible ? 1 : 0)  // Hide visually
                        .allowsHitTesting(isChatVisible)  // Disable interaction when hidden
                        .background(Color.black)
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

            // QR code overlay (only shown when payment is being made)
            if showZapQR, let option = selectedZapOption, let uri = invoiceURI {
                ZapQRCodeView(
                    invoiceURI: uri,
                    zapOption: option,
                    onDismiss: {
                        showZapQR = false
                        selectedZapOption = nil
                        invoiceURI = nil
                    }
                )
            }

            // Streamer profile side menu
            if showStreamerProfile, let stream = stream {
                StreamerProfilePopupView(
                    stream: stream,
                    authManager: authManager,
                    onDismiss: { showStreamerProfile = false }
                )
                .animation(.easeInOut(duration: 0.3), value: showStreamerProfile)
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
        .onChange(of: showZapQR) { oldValue, newValue in
            // Restore focus when QR dismissed
            if !newValue && oldValue {
                focusedField = .profileButton
            }
        }
        .onChange(of: showStreamerProfile) { oldValue, newValue in
            // Restore focus when profile dismissed
            if !newValue && oldValue {
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

    private func handleZapSelection(_ option: ZapOption) {
        showZapMenu = false
        selectedZapOption = option

        guard let stream = stream,
              let lightningAddress = lightningAddress else {
            print("❌ Missing required data for zap")
            return
        }

        // Generate zap request and show QR code
        Task {
            do {
                let generator = ZapRequestGenerator(nostrSDKClient: nostrSDKClient, authManager: authManager)
                let uri = try await generator.generateZapRequest(
                    stream: stream,
                    amount: option.amount,
                    comment: option.message,
                    lud16: lightningAddress
                )

                await MainActor.run {
                    invoiceURI = uri
                    showZapQR = true
                }
                // Zap receipts will arrive automatically via the persistent subscription
            } catch {
                print("❌ Failed to generate zap request: \(error)")
            }
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

        Task {
            do {
                try await liveActivityManager.sendChatMessage(chatMessage)

                await MainActor.run {
                    // Clear input
                    chatMessage = ""
                }
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
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = CustomAVPlayerViewController()
        controller.player = player
        controller.stream = stream
        controller.onDismiss = onDismiss
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// Custom controller that disables the idle timer
class CustomAVPlayerViewController: AVPlayerViewController {
    var stream: Stream?  // Stream being watched (for reference)
    var onDismiss: (() -> Void)?  // Closure to dismiss the view

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
        // Handle Menu button press to dismiss the player
        for press in presses {
            if press.type == .menu {
                onDismiss?()
                return
            }
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
            TextField("Type message...", text: $message)
                .font(.system(size: 18))
                .padding(.horizontal, 12)
                .foregroundColor(.white)
                .focused($focusedField, equals: .textField)
                .frame(width: 241, height: 58)

            // Send button - icon only
            ChatActionButton(
                icon: "paperplane.fill",
                color: .green,
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
                .foregroundColor(isChatVisible ? .orange : .green)
                .frame(width: 58, height: 58)
        }
        .buttonStyle(.card)
    }
}
