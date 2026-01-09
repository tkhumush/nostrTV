//
//  ZapChyronView.swift
//  nostrTV
//
//  Created by Claude Code
//

import SwiftUI

/// A chyron banner that displays zap comments one at a time
/// Rotates through the latest 10 zaps with a 7-second timer per zap
struct ZapChyronView: View {
    let zapComments: [ZapComment]
    let nostrSDKClient: NostrSDKClient
    @ObservedObject var zapManager: ZapManager

    @State private var currentIndex: Int = 0
    @State private var timer: Timer?

    private let displayDuration: Double = 7.0 // Seconds per zap
    private let maxZapsToShow: Int = 10

    var body: some View {
        // Use profileUpdateTrigger to force view refresh when profiles change
        let _ = zapManager.profileUpdateTrigger

        return content
    }

    private var content: some View {
        ZStack {
            // Solid black background
            Rectangle()
                .fill(Color.black)
                .frame(height: 120)

            // Display current zap or placeholder
            if !zapComments.isEmpty {
                let displayZaps = Array(zapComments.prefix(maxZapsToShow))
                if !displayZaps.isEmpty {
                    ZapDisplayView(zap: displayZaps[currentIndex], nostrSDKClient: nostrSDKClient)
                        .id(displayZaps[currentIndex].id) // Force view update on change
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity
                        ))
                }
            } else {
                // Placeholder when no zaps
                Text("No zaps yet - be the first to zap!")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.gray)
            }
        }
        .frame(height: 120)
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: zapComments.count) { oldValue, newValue in
            // Reset to first zap when new zaps arrive
            if newValue > oldValue {
                currentIndex = 0
            }
            // Restart timer with new data
            startTimer()
        }
    }

    private func startTimer() {
        stopTimer()

        guard !zapComments.isEmpty else { return }

        timer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                let displayZaps = Array(zapComments.prefix(maxZapsToShow))
                if !displayZaps.isEmpty {
                    currentIndex = (currentIndex + 1) % displayZaps.count
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// View that displays a single zap with formatted text
private struct ZapDisplayView: View {
    let zap: ZapComment
    let nostrSDKClient: NostrSDKClient

    var body: some View {
        // Dynamically fetch profile name from NostrSDKClient
        let profile = nostrSDKClient.getProfile(for: zap.senderPubkey)
        let displayName = profile?.displayName ?? profile?.name ?? "Anonymous"

        HStack(spacing: 12) {
            // Zap emoji
            Text("⚡️")
                .font(.system(size: 40))

            // Zap information
            VStack(alignment: .leading, spacing: 4) {
                // First line: Name + amount
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    Text("zapped")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))

                    Text("\(zap.amountInSats) sats")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.yellow)
                }

                // Second line: Comment (if present)
                if !zap.comment.isEmpty {
                    HStack(spacing: 6) {
                        Text("and said:")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))

                        Text(zap.comment)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
    }
}

#Preview {
    let nostrSDKClient = try! NostrSDKClient()
    let zapManager = ZapManager(nostrSDKClient: nostrSDKClient)

    ZStack {
        Color.blue
        VStack {
            Spacer()
            ZapChyronView(
                zapComments: [
                ZapComment(
                    id: "1",
                    amount: 1000000,
                    senderPubkey: "test",
                    senderName: "Alice",
                    comment: "Great stream!",
                    timestamp: Date(),
                    streamEventId: "stream1"
                ),
                ZapComment(
                    id: "2",
                    amount: 500000,
                    senderPubkey: "test2",
                    senderName: "Bob",
                    comment: "Love this content",
                    timestamp: Date(),
                    streamEventId: "stream1"
                ),
                ZapComment(
                    id: "3",
                    amount: 2000000,
                    senderPubkey: "test3",
                    senderName: nil,
                    comment: "",
                    timestamp: Date(),
                    streamEventId: "stream1"
                )
            ],
                nostrSDKClient: nostrSDKClient,
                zapManager: zapManager
            )
            .padding(.bottom, 40)
        }
    }
}
