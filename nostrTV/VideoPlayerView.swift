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
    let zapManager: ZapManager?
    let authManager: NostrAuthManager

    @State private var showZapMenu = false
    @State private var showZapQR = false
    @State private var selectedZapOption: ZapOption?
    @State private var invoiceURI: String?

    var body: some View {
        ZStack {
            // Main layout
            VStack(spacing: 0) {
                // Video player takes most of the screen
                VideoPlayerContainer(
                    player: player,
                    stream: stream,
                    nostrClient: nostrClient
                )

                // Bottom bar with zap button, menu options, and chyron
                HStack(spacing: 0) {
                    // Zap button - square in bottom left corner
                    if lightningAddress != nil {
                        Button(action: {
                            showZapMenu.toggle()
                        }) {
                            Rectangle()
                                .fill(Color.yellow)
                                .frame(width: 120, height: 120)
                                .cornerRadius(0)
                                .overlay(
                                    Text("⚡️")
                                        .font(.system(size: 60))
                                )
                        }
                        .buttonStyle(SquareCardButtonStyle())
                        .frame(width: 120, height: 120)
                    }

                    // Zap menu options - shown inline next to button
                    if showZapMenu {
                        ZapMenuOptionsView(
                            onZapSelected: { option in
                                handleZapSelection(option)
                            },
                            onDismiss: {
                                showZapMenu = false
                            }
                        )
                    }

                    // Zap chyron - stretches across remaining space
                    if let stream = stream, let zapManager = zapManager {
                        let zapStreamId = stream.eventID ?? stream.streamID
                        ZapChyronWrapper(zapManager: zapManager, streamId: zapStreamId)
                            .frame(height: 120)
                    } else {
                        Spacer()
                            .frame(height: 120)
                    }
                }
                .background(Color.black.opacity(0.3))
            }

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
            // Fetch zaps for this stream when view appears
            if let stream = stream, let eventID = stream.eventID, let zapManager = zapManager {
                print("🎬 Fetching zaps for stream:")
                print("   Event ID: \(eventID)")
                print("   Stream ID (d-tag): \(stream.streamID)")
                print("   Pubkey: \(stream.pubkey ?? "nil")")
                zapManager.fetchZapsForStream(eventID, pubkey: stream.pubkey, dTag: stream.streamID)
            }
        }
        .onDisappear {
            // Clear zap subscriptions when view disappears
            if let stream = stream, let eventID = stream.eventID, let zapManager = zapManager {
                print("📪 Closing zap subscriptions for stream")
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
                }
            } catch {
                print("❌ Failed to generate zap request: \(error)")
            }
        }
    }
}

/// Container for the AVPlayerViewController
struct VideoPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let stream: Stream?
    let nostrClient: NostrClient

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = CustomAVPlayerViewController()
        controller.player = player
        controller.stream = stream
        controller.nostrClient = nostrClient
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
    let streamId: String

    var body: some View {
        ZapChyronView(zapComments: zapManager.getZapsForStream(streamId))
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
