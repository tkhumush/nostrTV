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

                        VStack(alignment: .leading, spacing: 8) {
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

                        // Invisible anchor at the very bottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .focusable(false)  // Prevent ScrollView from capturing focus
                    .background(Color.coveBackground)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: activityManager.updateTrigger) { _, _ in
                        if let lastMessage = messages.last {
                            // Small delay lets the layout engine place the new row
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
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

                // Message content, with `nostr:` mentions resolved to names
                messageContent
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.coveOverlay.opacity(0.5))
        .cornerRadius(CoveUI.smallCornerRadius)
        .onAppear {
            // Fetch any mentioned profile we do not have yet. Done here rather than
            // while building the body so rendering stays free of side effects; the
            // client debounces and deduplicates, so repeat rows are cheap. When a
            // profile lands, `updateTrigger` re-renders and the name fills in.
            for pubkey in NostrMention.mentionedPubkeys(in: message.message)
            where nostrClient.getProfile(for: pubkey) == nil {
                nostrClient.requestProfile(for: pubkey)
            }
        }
    }

    /// Message text with mentions shown as the tagged person's name.
    ///
    /// Built by concatenating `Text` rather than as separate views so the message still
    /// wraps as one paragraph, with mentions styled inline.
    private var messageContent: Text {
        NostrMention.parse(message.message).reduce(Text("")) { result, segment in
            switch segment {
            case .text(let plain):
                return result + Text(plain)
            case .mention(let pubkey, let identifier):
                return result + Text(mentionLabel(pubkey: pubkey, identifier: identifier))
                    .foregroundColor(.coveAccent)
                    .fontWeight(.semibold)
            }
        }
    }

    /// Display name for a mention, falling back to a truncated identifier.
    ///
    /// The fallback covers both a profile still in flight and someone who has never
    /// published one — neither should render as sixty characters of base32.
    private func mentionLabel(pubkey: String, identifier: String) -> String {
        if let profile = nostrClient.getProfile(for: pubkey) {
            if let name = profile.displayName ?? profile.name, !name.isEmpty {
                return "@\(name)"
            }
        }
        return "@\(identifier.prefix(10))…"
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short  // Shows date (e.g., 1/8/26)
        formatter.timeStyle = .short  // Shows time (e.g., 2:30 PM)
        return formatter.string(from: date)
    }
}

#Preview {
    let nostrClient = (try? NostrSDKClient())
        ?? NostrSDKClient.errorClient(message: "Preview client init failed")
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
