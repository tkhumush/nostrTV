import SwiftUI

struct LiveChatView: View {
    @ObservedObject var activityManager: StreamActivityManager
    let stream: Stream
    let nostrClient: NostrSDKClient
    @State private var followsLive = true
    @FocusState private var focusedEntry: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entries: [CoveChatEntry] {
        (activityManager.chatMessages.map(CoveChatEntry.message) + activityManager.zapComments.map(CoveChatEntry.zap))
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 40)).foregroundStyle(Color.coveAccent)
                    Text("It’s quiet in here.").font(.coveBody)
                    Text("Be the first to say hello.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 12) {
                        Button {
                            followsLive.toggle()
                            if followsLive { focusedEntry = nil; proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        } label: {
                            Label(followsLive ? "Read history" : "Jump to live", systemImage: followsLive ? "clock" : "arrow.down")
                        }.buttonStyle(CoveButtonStyle()).padding(.top, 16)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                ForEach(entries) { entry in
                                    Group {
                                        switch entry {
                                        case .message(let message):
                                            ChatMessageRow(message: message, nostrClient: nostrClient, updateTrigger: activityManager.updateTrigger)
                                        case .zap(let zap):
                                            zapRow(zap)
                                        }
                                    }
                                    .padding(6)
                                    .background(focusedEntry == entry.id ? Color.coveOverlay : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .focusable(!followsLive)
                                    .focused($focusedEntry, equals: entry.id)
                                    .id(entry.id)
                                }
                                Color.clear.frame(height: 1).id("chat-bottom")
                            }.padding(.horizontal, 24).padding(.vertical, 24)
                        }
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: entries.map(\.id)) { _, _ in
                            guard followsLive else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        }
                        .onChange(of: focusedEntry) { _, entry in
                            if let entry { proxy.scrollTo(entry, anchor: .center) }
                        }
                    }
                }
            }
        }.frame(maxHeight: .infinity).background(Color.coveSurface)
    }

    private func zapRow(_ zap: ZapComment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.fill").foregroundStyle(Color.coveGold)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Profile.chatName(profile: nostrClient.getProfile(for: zap.senderPubkey), pubkey: zap.senderPubkey, fallbackName: zap.senderName)) sent \(zap.amountInSats.formatted()) sats")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(Color.coveGold)
                if !zap.comment.isEmpty { Text(zap.comment).font(.system(size: 22)).foregroundStyle(.white) }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.coveGold.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private enum CoveChatEntry: Identifiable {
    case message(ChatMessage)
    case zap(ZapComment)
    var id: String {
        switch self { case .message(let m): return "message-" + m.id; case .zap(let z): return "zap-" + z.id }
    }
    var timestamp: Date {
        switch self { case .message(let m): return m.timestamp; case .zap(let z): return z.timestamp }
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
        let displayName = Profile.chatName(profile: profile, pubkey: message.senderPubkey)

        // Use the trigger to force re-computation (SwiftUI dependency tracking)
        let _ = updateTrigger

        HStack(alignment: .top, spacing: 14) {
            CoveAvatar(profile: profile, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                // Username and timestamp
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.coveAccent)

                    Text(timeString(from: message.timestamp))
                        .font(.system(size: 22))
                        .foregroundColor(.coveSecondary)
                }

                // Message content, with `nostr:` mentions resolved to names
                messageContent
                    .font(.system(size: 22))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.clear)
        .cornerRadius(CoveUI.smallCornerRadius)
        .onAppear {
            if nostrClient.getProfile(for: message.senderPubkey) == nil {
                nostrClient.requestProfile(for: message.senderPubkey)
            }
            // Fetch any mentioned profile we do not have yet. Done here rather than
            // while building the body so rendering stays free of side effects; the
            // client debounces and deduplicates, so repeat rows are cheap. When a
            // profile lands, `updateTrigger` re-renders and the name fills in.
            for target in NostrMention.mentionTargets(in: message.message)
            where nostrClient.getProfile(for: target.pubkey) == nil {
                // Follow the nprofile's relay hints. Someone tagged this way is often
                // not on our default relays — carrying hints is the entire reason the
                // identifier exists rather than a plain npub — so without this their
                // metadata is never found and the mention stays unresolved.
                if !target.relays.isEmpty {
                    nostrClient.addRelays(target.relays)
                }
                nostrClient.requestProfile(for: target.pubkey)
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
            if let name = profile.preferredName {
                return "@\(name)"
            }
        }
        return "@\(identifier.prefix(10))…"
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
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
