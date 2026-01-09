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
    @State private var lastZapRequestPubkey: String?
    @State private var liveActivityManager: LiveActivityManager?
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

        // Phase 2: Use shared NostrSDKClient for ChatManager
        // This prevents creating multiple client instances
        // TODO: Phase 3 will pass this from ContentView properly
        _chatManager = StateObject(wrappedValue: ChatManager(nostrClient: NostrSDKClient.sharedForChat))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Unified banner across entire top
                if let stream = stream {
                    HStack(spacing: 12) {
                        // nostrTV logo
                        Text("nostrTV")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)

                        Text("|")
                            .font(.system(size: 18))
                            .foregroundColor(.gray)

                        // Stream info: profile pic + username + stream name
                        HStack(spacing: 8) {
                            // Profile picture
                            if let profile = stream.profile, let pictureURL = profile.picture, let url = URL(string: pictureURL) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 32, height: 32)
                                            .clipShape(Circle())
                                    case .failure(_), .empty:
                                        Circle()
                                            .fill(Color.gray)
                                            .frame(width: 32, height: 32)
                                    @unknown default:
                                        Circle()
                                            .fill(Color.gray)
                                            .frame(width: 32, height: 32)
                                    }
                                }
                            } else {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 32, height: 32)
                            }

                            // Username
                            Text(stream.profile?.displayName ?? stream.profile?.name ?? "Anonymous")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)

                            // Stream name
                            Text(stream.title)
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                        }

                        Spacer()

                        // Viewer count on far right
                        HStack(spacing: 8) {
                            Text("|")
                                .font(.system(size: 18))
                                .foregroundColor(.gray)

                            Image(systemName: "eye.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)

                            Text("\(stream.viewerCount)")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                }

                // Main content - Split between video and chat
                HStack(spacing: 0) {
                    // Left side: Video player and controls
                    VStack(spacing: 0) {
                        // Video player takes most of the screen
                        VideoPlayerContainer(
                            player: player,
                            stream: stream,
                            nostrClient: nostrClient,
                            onDismiss: { dismiss() }
                        )

                    // Bottom bar with zap chyron and chat button
                    HStack(spacing: 0) {
                        // Zap chyron
                        if let stream = stream, let zapManager = zapManager {
                            ZapChyronWrapper(zapManager: zapManager, stream: stream, nostrSDKClient: nostrSDKClient)
                                .frame(height: 102)
                        } else {
                            Spacer()
                                .frame(height: 102)
                        }
                    }
                    .background(Color.black.opacity(0.3))
                }
                .focusSection()  // Separate focus section for video

                // Right side: Live chat
                if let stream = stream {
                    VStack(spacing: 0) {
                        LiveChatView(
                            chatManager: chatManager,
                            stream: stream,
                            nostrClient: NostrSDKClient.sharedForChat
                        )

                        // Chat input area
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
                            .frame(height: 90)
                        } else {
                            // Show "Type a message" button when not typing - matching Send/Cancel style
                            TypeMessageButton(action: { showChatInput = true })
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: 425)  // Fixed width for chat column (reduced by 15%)
                    .background(Color.black)
                    .focusSection()  // Separate focus section for chat
                }
            }
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
        }
        .ignoresSafeArea()
        .onAppear {
            // Initialize LiveActivityManager with authManager for signing
            liveActivityManager = LiveActivityManager(nostrClient: nostrClient, authManager: authManager)

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

            // Stop refresh timer
            zapRefreshTimer?.invalidate()
            zapRefreshTimer = nil

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
                let keyPair = try NostrKeyPair.generate()
                let zapSenderPubkey = keyPair.publicKeyHex

                let generator = ZapRequestGenerator(nostrClient: nostrClient)
                let uri = try await generator.generateZapRequest(
                    stream: stream,
                    amount: option.amount,
                    comment: option.message,
                    lud16: lightningAddress,
                    keyPair: keyPair
                )

                await MainActor.run {
                    invoiceURI = uri
                    showZapQR = true
                    lastZapRequestPubkey = zapSenderPubkey
                }

                // Wait 30 seconds and query for our zap receipt
                print("⏱️ Waiting 30 seconds to check for zap receipt...")
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds

                await MainActor.run {
                    queryForOurZapReceipt(zapSenderPubkey: zapSenderPubkey)
                }
            } catch {
                print("❌ Failed to generate zap request: \(error)")
            }
        }
    }

    private func queryForOurZapReceipt(zapSenderPubkey: String) {
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

// Custom controller that disables the idle timer and manages live activity
class CustomAVPlayerViewController: AVPlayerViewController {
    private var presenceTimer: Timer?  // Timer for periodic presence updates
    var stream: Stream?  // Stream being watched
    var nostrClient: NostrClient?  // NostrClient for publishing events
    private var liveActivityManager: LiveActivityManager?
    var onDismiss: (() -> Void)?  // Closure to dismiss the view

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true

        // Initialize LiveActivityManager with the shared NostrClient (which has active connections)
        if let nostrClient = nostrClient {
            liveActivityManager = LiveActivityManager(nostrClient: nostrClient)
        }

        // Announce joining the stream
        if let stream = stream, let activityManager = liveActivityManager {
            Task {
                do {
                    try await activityManager.joinStreamWithConnection(stream)
                    // Start periodic presence updates
                    startPresenceUpdates()
                } catch {
                    print("❌ Error joining stream: \(error)")
                }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false

        // Stop presence updates
        presenceTimer?.invalidate()
        presenceTimer = nil

        // Announce leaving the stream
        if let stream = stream, let activityManager = liveActivityManager {
            Task {
                do {
                    try await activityManager.leaveStream(stream)
                } catch {
                    // Failed to announce leaving stream
                }
            }
        }
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

    private func startPresenceUpdates() {
        // Update presence every 60 seconds to show continued viewing
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self, let activityManager = self.liveActivityManager else { return }
            Task {
                do {
                    try await activityManager.updatePresence()
                } catch {
                    // Failed to update presence
                }
            }
        }
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

/// Custom button style that mimics .card but with sharp corners
private struct SquareCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.1 : 1.0) // Lift effect when focused
            .shadow(color: .black.opacity(0.3), radius: isFocused ? 10 : 0, x: 0, y: isFocused ? 5 : 0)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            .clipShape(Rectangle()) // Force sharp corners
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
private struct ChatActionButton: View {
    let label: String
    let color: Color
    let action: () -> Void

    @Environment(\.isFocused) var isFocused: Bool

    var body: some View {
        ZStack {
            // Background glow indicator when focused
            if isFocused {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 105, height: 105)
                    .blur(radius: 20)
            }

            // Focus indicator - 5% larger square with yellow border
            if isFocused {
                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 4)
                    .frame(width: 95, height: 95) // 90 * 1.05 = 94.5
            }

            // Button
            Button(action: action) {
                Rectangle()
                    .fill(color)
                    .frame(width: 90, height: 90)
                    .overlay(
                        Text(label)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    )
            }
            .buttonStyle(SquareCardButtonStyle())
        }
    }
}

/// Type message button matching the square chat action button style
private struct TypeMessageButton: View {
    let action: () -> Void

    @Environment(\.isFocused) var isFocused: Bool

    var body: some View {
        ZStack {
            // Background glow indicator when focused
            if isFocused {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 70)
                    .blur(radius: 20)
            }

            // Focus indicator - 5% larger square with yellow border
            if isFocused {
                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 4)
                    .frame(height: 63) // 60 * 1.05 = 63
            }

            // Button
            Button(action: action) {
                Rectangle()
                    .fill(Color.purple)
                    .frame(height: 60)
                    .overlay(
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 18))
                            Text("Type a message")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .foregroundColor(.white)
                    )
            }
            .buttonStyle(SquareCardButtonStyle())
        }
    }
}
