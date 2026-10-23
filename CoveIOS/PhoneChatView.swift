import SwiftUI

struct PhoneChatView: View {
    @ObservedObject var session: PhoneWatchSession
    @EnvironmentObject private var auth: NostrAuthManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Width of system controls this panel runs underneath (Duo's vertical bar).
    var controlsInset: CGFloat = 0
    /// A raised keyboard lifts the composer up alongside those controls.
    var keyboardRaised = false
    let onSignIn: () -> Void
    @State private var followsLive = true

    private var entries: [PhoneChatEntry] {
        #if DEBUG
        if CoveUITestSupport.enabled { return PhoneChatEntry.preview }
        #endif
        return (session.activity.chatMessages.map(PhoneChatEntry.message) + session.activity.zapComments.map(PhoneChatEntry.zap))
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    HStack {
                        Text("Live chat").font(.subheadline.bold())
                        Spacer()
                        Button(followsLive ? "Read history" : "Jump to live") {
                            followsLive.toggle()
                            if followsLive { proxy.scrollTo("bottom", anchor: .bottom) }
                        }.font(.caption).accessibilityIdentifier("phone-chat-history")
                    }.padding(.horizontal).padding(.vertical, 12).padding(.trailing, controlsInset)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if entries.isEmpty { Text("It’s quiet in here. Say hello!").font(.callout).foregroundStyle(Color.coveSecondary) }
                            ForEach(entries) { entry in row(entry) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding()
                    }
                    .accessibilityIdentifier("phone-chat-timeline")
                    .defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.interactively)
                    .onChange(of: entries.map(\.id)) { _, _ in
                        guard followsLive else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            Divider()
            composer
        }.background(Color.coveSurface)
            .accessibilityElement(children: .contain).accessibilityIdentifier("phone-chat")
    }

    private func row(_ entry: PhoneChatEntry) -> some View {
        let profile = session.activity.getProfile(for: entry.pubkey)
        return HStack(alignment: .top, spacing: 10) {
            if entry.isZap { Image(systemName: "bolt.fill").foregroundStyle(Color.coveGold) }
            else { CoveAvatar(profile: profile, size: 28) }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.isZap ? "\(entry.name(profile)) sent \(entry.sats.formatted()) sats" : entry.name(profile))
                    .font(.caption.bold()).foregroundStyle(entry.isZap ? Color.coveGold : Color.coveAccent)
                Text(messageText(entry.content)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(entry.isZap ? 12 : 0)
            .background(entry.isZap ? Color.coveGold.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if auth.isAuthenticated {
                // Field and button share a 44 pt line, so a single line is centred
                // and the button stays beside the last line as the field grows.
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Say hello…", text: $session.draft, axis: .vertical)
                        .lineLimit(1...4).accessibilityIdentifier("phone-chat-message")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .background(Color.coveBackground, in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.coveOverlay))
                    Button { Task { await session.send(using: auth) } } label: {
                        if session.sending { ProgressView() }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    }.frame(width: 44, height: 44)
                        .disabled(session.sending || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send message")
                }
                if let error = session.sendError { Text(error).font(.caption).foregroundStyle(Color.coveGold) }
            } else {
                Button("Sign in to join the conversation", action: onSignIn).frame(maxWidth: .infinity, minHeight: 44)
            }
        }.padding()
            // Below the vertical bar the composer can reach the edge, clear of the
            // display's rounded corner; with the keyboard up it sits beside the bar.
            .padding(.trailing, keyboardRaised ? controlsInset : min(controlsInset, 8))
    }

    private func messageText(_ content: String) -> String {
        NostrMention.parse(content).map { segment in
            switch segment {
            case .text(let text): return text
            case .mention(let pubkey, _): return "@" + Profile.chatName(profile: session.activity.getProfile(for: pubkey), pubkey: pubkey)
            }
        }.joined()
    }
}

private enum PhoneChatEntry: Identifiable {
    case message(ChatMessage), zap(ZapComment)
    var id: String { switch self { case .message(let m): return "m-" + m.id; case .zap(let z): return "z-" + z.id } }
    var timestamp: Date { switch self { case .message(let m): return m.timestamp; case .zap(let z): return z.timestamp } }
    var pubkey: String { switch self { case .message(let m): return m.senderPubkey; case .zap(let z): return z.senderPubkey } }
    var content: String { switch self { case .message(let m): return m.message; case .zap(let z): return z.comment } }
    var isZap: Bool { if case .zap = self { return true }; return false }
    var sats: Int { if case .zap(let z) = self { return z.amountInSats }; return 0 }
    func name(_ profile: Profile?) -> String {
        let fallback: String? = { if case .zap(let z) = self { return z.senderName }; return nil }()
        return Profile.chatName(profile: profile, pubkey: pubkey, fallbackName: fallback)
    }
    #if DEBUG
    static var preview: [Self] {
        [.message(ChatMessage(id: "1", senderPubkey: "coastline", message: "A good place to spend the afternoon.", timestamp: Date(timeIntervalSince1970: 1))),
         .zap(ZapComment(id: "2", amount: 21000, senderPubkey: "listener", senderName: "A listener", comment: "Thanks for the company!", timestamp: Date(timeIntervalSince1970: 2), streamEventId: nil, bolt11: nil)),
         .message(ChatMessage(id: "3", senderPubkey: "outside", message: "Hello from the other side of the world 🌊", timestamp: Date(timeIntervalSince1970: 3)))]
    }
    #endif
}
