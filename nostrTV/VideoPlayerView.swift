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
    let nostrClient: NostrClient
    let nostrSDKClient: NostrSDKClient
    let zapManager: ZapManager?
    let authManager: NostrAuthManager

    @State private var showZapMenu = false
    @State private var showZapQR = false
    @State private var selectedZapOption: ZapOption?
    @State private var invoiceURI: String?
    @State private var zapRefreshTimer: Timer?
    @State private var presenceTimer: Timer?
    @State private var liveActivityManager: LiveActivityManager?
    @State private var showStreamerProfile = false
    @StateObject private var chatManager: ChatManager
    @State private var showChatInput = false
    @State private var chatMessage = ""
    @Environment(\.dismiss) private var dismiss

    init(player: AVPlayer, lightningAddress: String?, stream: Stream?, nostrClient: NostrClient, nostrSDKClient: NostrSDKClient, zapManager: ZapManager?, authManager: NostrAuthManager) {
        self.player = player
        self.lightningAddress = lightningAddress
        self.stream = stream
        self.nostrClient = nostrClient
        self.nostrSDKClient = nostrSDKClient
        self.zapManager = zapManager
        self.authManager = authManager

        // Use the SDK client passed from ContentView
        _chatManager = StateObject(wrappedValue: ChatManager(nostrClient: nostrSDKClient))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Unified banner across entire top
                if let stream = stream {
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

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .focusSection()
                }

                // Row 2: Video player (83%) and Live chat (17%)
                HStack(spacing: 0) {
                    // Video player (83%)
                    VideoPlayerContainer(
                        player: player,
                        stream: stream,
                        nostrClient: nostrClient,
                        onDismiss: { dismiss() }
                    )
                    .frame(maxWidth: .infinity)

                    // Live chat column (17% - fixed width)
                    if let stream = stream {
                        LiveChatView(
                            chatManager: chatManager,
                            stream: stream,
                            nostrClient: nostrSDKClient
                        )
                        .frame(width: 375)  // 17% of typical 1920px width (~326px) + padding
                        .background(Color.black)
                    }
                }

                // Row 3: Zap chyron (83%) and Comment button (17%)
                HStack(spacing: 0) {
                    // Zap chyron (83%)
                    if let stream = stream, let zapManager = zapManager {
                        ZapChyronWrapper(zapManager: zapManager, stream: stream, nostrSDKClient: nostrSDKClient)
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer()
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                    }

                    // Comment button (17% - fixed width)
                    if let stream = stream {
                        VStack(spacing: 0) {
                            if showChatInput {
                                ChatInputView(
                                    message: $chatMessage,
                                    onSend: {
                                        sendChatMessage()
                                    },
                                    onDismiss: {
                                        showChatInput = false
                                        chatMessage = ""
                                    }
                                )
                                .frame(height: 110)
                                .padding(.horizontal, 16)
                            } else {
                                TypeMessageButton(action: { showChatInput = true })
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 16)
                            }
                        }
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

            // Fetch zaps for this stream when view appears
            if let stream = stream, let eventID = stream.eventID, let zapManager = zapManager, let pubkey = stream.pubkey {
                // Fetch zap receipts (kind 9735)
                zapManager.fetchZapsForStream(eventID, pubkey: pubkey, dTag: stream.streamID)

                // Start periodic refresh every 30 seconds
                startZapRefreshTimer()
            }

            // Start presence updates for bunker-authenticated users
            if authManager.authMethod != nil, case .bunker = authManager.authMethod {
                startPresenceTimer()
            }

            // Fetch chat messages for this stream
            if let stream = stream, let eventID = stream.eventID, let authorPubkey = stream.eventAuthorPubkey {
                // IMPORTANT: Use eventAuthorPubkey (not host pubkey) for a-tag coordinate
                // Chat messages reference: "30311:<event-author-pubkey>:<d-tag>"
                chatManager.fetchChatMessagesForStream(eventID, pubkey: authorPubkey, dTag: stream.streamID)
            }
        }
        .onDisappear {
            // Leave the stream
            if let activityManager = liveActivityManager {
                Task {
                    do {
                        try await activityManager.leaveCurrentStream()
                    } catch {
                        print("❌ Error leaving stream: \(error)")
                    }
                }
            }

            // Stop refresh timers
            zapRefreshTimer?.invalidate()
            zapRefreshTimer = nil
            presenceTimer?.invalidate()
            presenceTimer = nil

            // Clear zap subscriptions when view disappears
            if let stream = stream, let eventID = stream.eventID, let zapManager = zapManager {
                zapManager.clearZapsForStream(eventID)
            }
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

                // Wait 30 seconds and query for our zap receipt
                print("⏱️ Waiting 30 seconds to check for zap receipt...")
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds

                await MainActor.run {
                    queryForOurZapReceipt()
                }
            } catch {
                print("❌ Failed to generate zap request: \(error)")
            }
        }
    }

    private func queryForOurZapReceipt() {
        guard let stream = stream, let zapManager = zapManager else { return }

        // Refresh the zap request for this stream
        if let eventID = stream.eventID {
            zapManager.fetchZapsForStream(eventID, pubkey: stream.pubkey, dTag: stream.streamID)
        }
    }

    private func startZapRefreshTimer() {
        // Refresh zaps every 30 seconds
        zapRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [self] _ in
            if let stream = stream, let eventID = stream.eventID, let zapManager = zapManager {
                zapManager.fetchZapsForStream(eventID, pubkey: stream.pubkey, dTag: stream.streamID)
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
                    // Clear input and hide keyboard
                    chatMessage = ""
                    showChatInput = false
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
    let nostrClient: NostrClient
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = CustomAVPlayerViewController()
        controller.player = player
        controller.stream = stream
        controller.nostrClient = nostrClient
        controller.onDismiss = onDismiss
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// Custom controller that disables the idle timer
class CustomAVPlayerViewController: AVPlayerViewController {
    var stream: Stream?  // Stream being watched (for reference)
    var nostrClient: NostrClient?  // Legacy NostrClient (for reference)
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

// Wrapper view to observe zapManager and pass zap comments to the chyron
struct ZapChyronWrapper: View {
    @ObservedObject var zapManager: ZapManager
    let stream: Stream
    let nostrSDKClient: NostrSDKClient

    var body: some View {
        // Try both eventID and a-tag format for lookup
        let eventId = stream.eventID ?? stream.streamID
        var zaps = zapManager.getZapsForStream(eventId)

        // If no zaps found with eventID, try a-tag format
        if zaps.isEmpty, let pubkey = stream.pubkey {
            let aTag = "30311:\(pubkey.lowercased()):\(stream.streamID)"
            zaps = zapManager.getZapsForStream(aTag)
        }

        return ZapChyronView(zapComments: zaps, nostrSDKClient: nostrSDKClient, zapManager: zapManager)
    }
}

/// Chat input view for sending messages
struct ChatInputView: View {
    @Binding var message: String
    let onSend: () -> Void
    let onDismiss: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Text field container - reduced size
            ZStack {
                Rectangle()
                    .fill(Color.gray)
                    .frame(width: 245, height: 90)

                TextField("Type your message...", text: $message)
                    .padding(12)
                    .foregroundColor(.white)
                    .focused($isTextFieldFocused)
                    .frame(width: 225)
            }
            .frame(width: 245, height: 90)

            // Send button - reduced size
            ChatActionButton(
                label: "Send",
                color: .green,
                action: onSend
            )

            // Cancel button - reduced size
            ChatActionButton(
                label: "Cancel",
                color: .gray,
                action: onDismiss
            )
        }
    }
}

/// Individual chat action button matching the square zap menu style
/// Chat action button with native Liquid Glass style
private struct ChatActionButton: View {
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 90, height: 90)
        }
        .buttonStyle(.borderedProminent)
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
