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
    @ObservedObject var chatManager: ChatManager
    let stream: Stream
    let nostrClient: NostrClient

    @State private var shouldAutoScroll = true
    @State private var uniqueMessages: [ChatMessage] = []
    @State private var lastUpdateTime: Date = Date()

    var body: some View {
        let streamId = stream.eventID ?? stream.streamID
        let aTag = stream.pubkey.map { "30311:\($0.lowercased()):\(stream.streamID)" }
        let messages = chatManager.getMessagesForStream(streamId)
            + chatManager.getMessagesForStream(aTag ?? "")

        // Force view refresh when profiles change OR messages change
        let _ = chatManager.profileUpdateTrigger
        let _ = chatManager.messageUpdateTrigger

        ZStack {
            // Black background
            Rectangle()
                .fill(Color.black)

            VStack(spacing: 0) {
                // Viewer count ribbon at top
                HStack(spacing: 5) {
                    Spacer()

                    Image(systemName: "eye.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)

                    Text("\(stream.viewerCount)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10) // 9 * 1.1 = 9.9, rounded to 10
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.gray)

                Divider()
                    .background(Color.gray.opacity(0.3))

                // Messages
                if uniqueMessages.isEmpty {
                    // Empty state
                    VStack(spacing: 12) {
                        Text("💭")
                            .font(.system(size: 60))
                        Text("No messages yet")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.gray)
                        Text("Be the first to chat!")
                            .font(.system(size: 16))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(uniqueMessages) { message in
                                    ChatMessageRow(message: message, nostrClient: nostrClient)
                                        .id(message.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: uniqueMessages.count) { oldValue, newValue in
                            // Auto-scroll to bottom when new messages arrive
                            if newValue > oldValue, shouldAutoScroll, let lastMessage = uniqueMessages.last {
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                        .onAppear {
                            // Scroll to bottom on appear
                            if let lastMessage = uniqueMessages.last {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: chatManager.messageUpdateTrigger) { _, _ in
            // Update cached deduplicated messages when chatManager's messages change
            let streamId = stream.eventID ?? stream.streamID
            let aTag = stream.pubkey.map { "30311:\($0.lowercased()):\(stream.streamID)" }
            let messages = chatManager.getMessagesForStream(streamId)
                + chatManager.getMessagesForStream(aTag ?? "")

            uniqueMessages = Dictionary(grouping: messages, by: { $0.id })
                .compactMap { $0.value.first }
                .sorted { $0.timestamp < $1.timestamp }
        }
        .onChange(of: chatManager.profileUpdateTrigger) { _, _ in
            // Force re-render when profiles update (for display names)
            lastUpdateTime = Date()
        }
        .onAppear {
            // Initial deduplication on appear
            let streamId = stream.eventID ?? stream.streamID
            let aTag = stream.pubkey.map { "30311:\($0.lowercased()):\(stream.streamID)" }
            let messages = chatManager.getMessagesForStream(streamId)
                + chatManager.getMessagesForStream(aTag ?? "")

            uniqueMessages = Dictionary(grouping: messages, by: { $0.id })
                .compactMap { $0.value.first }
                .sorted { $0.timestamp < $1.timestamp }
        }
    }
}

/// Individual chat message row
private struct ChatMessageRow: View {
    let message: ChatMessage
    let nostrClient: NostrClient

    var body: some View {
        // Dynamically fetch profile name from NostrClient
        let profile = nostrClient.getProfile(for: message.senderPubkey)
        let displayName = profile?.displayName ?? profile?.name ?? "Anonymous"

        VStack(alignment: .leading, spacing: 4) {
            // Username and timestamp
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.yellow)

                Text(timeString(from: message.timestamp))
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }

            // Message content
            Text(message.message)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    let nostrClient = NostrClient()
    let chatManager = ChatManager(nostrClient: nostrClient)

    // Add some sample messages
    let stream = Stream(
        streamID: "test-stream",
        eventID: "test-event",
        title: "Test Stream",
        streaming_url: "https://example.com",
        imageURL: nil,
        pubkey: "testpubkey",
        profile: nil,
        status: "live",
        tags: [],
        createdAt: Date(),
        viewerCount: 42
    )

    LiveChatView(chatManager: chatManager, stream: stream, nostrClient: nostrClient)
        .frame(width: 400)
}
