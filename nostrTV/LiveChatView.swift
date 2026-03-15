//
//  LiveChatView.swift
//  nostrTV
//
//  Created by Claude Code
//

import SwiftUI

/// Vertical live chat view similar to Twitch/YouTube chat
/// Displays chat messages in chronological order with auto-scroll
struct LiveChatView: View {
    @ObservedObject var activityManager: StreamActivityManager
    let stream: Stream
    let nostrClient: NostrSDKClient

    @State private var shouldAutoScroll = true

    var body: some View {
        // StreamActivityManager stores chat messages for the stream it's listening to
        let messages = activityManager.chatMessages

        // Force view refresh when activity changes
        let _ = activityManager.updateTrigger

        VStack(spacing: 0) {
            // Messages
            if messages.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 50))
                        .foregroundColor(.coveAccent.opacity(0.4))
                    Text(CoveCopy.noMessages)
                        .font(.coveCaption)
                        .foregroundColor(.coveSecondary)
                    Text(CoveCopy.noMessagesSub)
                        .font(.coveSmall)
                        .foregroundColor(.coveSecondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.coveBackground)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Spacer pushes content to the bottom like a chat app
                        Spacer(minLength: 0)

                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { message in
                                ChatMessageRow(
                                    message: message,
                                    nostrClient: nostrClient,
                                    updateTrigger: activityManager.updateTrigger
                                )
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                    }
                    .focusable(false)  // Prevent ScrollView from capturing focus
                    .background(Color.coveBackground)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: messages.count) { oldValue, newValue in
                        if newValue > oldValue, let lastMessage = messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(Color.coveBackground)
        .onAppear {
            print("🔍 LiveChatView: Displaying chat for stream: \(stream.streamID)")
            print("   eventAuthorPubkey: \(stream.eventAuthorPubkey ?? "nil")")
            print("   Current message count: \(messages.count)")
        }
        .onChange(of: activityManager.updateTrigger) { oldValue, newValue in
            print("🔍 LiveChatView: updateTrigger changed: \(oldValue) -> \(newValue)")
            print("   Total messages: \(activityManager.chatMessages.count)")
        }
    }
}

/// Individual chat message row
private struct ChatMessageRow: View {
    let message: ChatMessage
    let nostrClient: NostrSDKClient
    let updateTrigger: Int  // Forces re-render when activity updates

    var body: some View {
        // Dynamically fetch profile name from NostrSDKClient
        let profile = nostrClient.getProfile(for: message.senderPubkey)
        let displayName = profile?.displayName ?? profile?.name ?? "Anonymous"
        let pictureURL = profile?.picture

        // Use the trigger to force re-computation (SwiftUI dependency tracking)
        let _ = updateTrigger

        HStack(alignment: .top, spacing: 8) {
            // Profile picture (circular, 32x32)
            if let pictureURL = pictureURL, let url = URL(string: pictureURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                    case .failure(_), .empty:
                        // Fallback to default avatar
                        Circle()
                            .fill(Color.coveOverlay)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Text(String(displayName.prefix(1)).uppercased())
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.coveAccent)
                            )
                    @unknown default:
                        Circle()
                            .fill(Color.coveOverlay)
                            .frame(width: 32, height: 32)
                    }
                }
            } else {
                // Default avatar with first letter
                Circle()
                    .fill(Color.coveOverlay)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(String(displayName.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.coveAccent)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                // Username and timestamp
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.coveAccent)

                    Text(timeString(from: message.timestamp))
                        .font(.system(size: 14))
                        .foregroundColor(.coveSecondary)
                }

                // Message content
                Text(message.message)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.coveOverlay.opacity(0.5))
        .cornerRadius(CoveUI.smallCornerRadius)
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short  // Shows date (e.g., 1/8/26)
        formatter.timeStyle = .short  // Shows time (e.g., 2:30 PM)
        return formatter.string(from: date)
    }
}

#Preview {
    let nostrClient = try! NostrSDKClient()
    let activityManager = StreamActivityManager()

    let stream = Stream(
        streamID: "test-stream",
        eventID: "test-event",
        title: "Test Stream",
        streaming_url: "https://example.com",
        imageURL: nil,
        pubkey: "testpubkey",
        eventAuthorPubkey: "testauthorpubkey",
        profile: nil,
        status: "live",
        tags: [],
        createdAt: Date(),
        viewerCount: 42,
        recording: nil,
        startsAt: nil
    )

    LiveChatView(activityManager: activityManager, stream: stream, nostrClient: nostrClient)
        .frame(width: 400)
}
