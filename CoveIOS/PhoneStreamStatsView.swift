import SwiftUI

/// Audience totals and top supporters. Fills the player column when chat sits beside it.
struct PhoneStreamStatsView: View {
    @ObservedObject var stats: StreamStatsManager
    let stream: Stream
    let onZap: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                liveStatus
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { tiles }
                    VStack(spacing: 10) { tiles }
                }
                supporters
            }
            .padding(.horizontal).padding(.bottom)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain).accessibilityIdentifier("phone-stream-stats")
    }

    @ViewBuilder private var tiles: some View {
        tile(value: stats.viewerCount, label: stats.isLive ? "Watching" : "Viewers", icon: "eye.fill", tint: .coveAccent, id: "viewers")
        tile(value: stats.tally.likeCount, label: stats.tally.likeCount == 1 ? "Like" : "Likes", icon: "heart.fill", tint: .pink, id: "likes")
        tile(value: stats.tally.zapTotalSats, label: zapLabel, icon: "bolt.fill", tint: .coveGold, id: "zaps")
    }

    private var zapLabel: String {
        let zaps = stats.tally.zapCount
        return "Sats from \(zaps.formatted()) \(zaps == 1 ? "zap" : "zaps")"
    }

    private func tile(value: Int, label: String, icon: String, tint: Color, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(value.formatted(.number.notation(.compactName))).monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            .font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(Color.coveSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.coveSurface, in: RoundedRectangle(cornerRadius: 14))
        .animation(.default, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value.formatted()) \(label.lowercased())")
        .accessibilityIdentifier("phone-stat-\(id)")
    }

    @ViewBuilder private var liveStatus: some View {
        if stats.isLive, let start = stream.startsAt ?? stream.createdAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let elapsed = Duration.seconds(max(0, context.date.timeIntervalSince(start)))
                HStack(spacing: 6) {
                    Circle().fill(Color.coveGold).frame(width: 8, height: 8)
                    Text("Live for \(elapsed.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))")
                }
                .font(.caption.bold()).foregroundStyle(Color.coveSecondary)
            }
        } else if !stats.isLive {
            Text("Stream ended").font(.caption.bold()).foregroundStyle(Color.coveSecondary)
        }
    }

    @ViewBuilder private var supporters: some View {
        let top = stats.tally.topSupporters(3)
        VStack(alignment: .leading, spacing: 10) {
            Text("Top supporters").font(.subheadline.bold())
            if top.isEmpty {
                Text("No zaps yet. Be the first to support this stream.")
                    .font(.callout).foregroundStyle(Color.coveSecondary)
            }
            ForEach(Array(top.enumerated()), id: \.element.id) { rank, supporter in
                let profile = stats.profile(for: supporter.pubkey)
                HStack(spacing: 10) {
                    Text("\(rank + 1)").font(.caption.bold()).foregroundStyle(Color.coveSecondary).frame(width: 14)
                    CoveAvatar(profile: profile, size: 28)
                    Text(Profile.chatName(profile: profile, pubkey: supporter.pubkey, fallbackName: supporter.fallbackName))
                        .font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    Label("\(supporter.sats.formatted()) sats", systemImage: "bolt.fill")
                        .font(.caption.bold()).foregroundStyle(Color.coveGold).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            Button(action: onZap) {
                Label("Send a zap", systemImage: "bolt.fill").frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered).tint(.coveGold)
            .accessibilityIdentifier("phone-stats-zap")
        }
        .padding(12)
        .background(Color.coveSurface, in: RoundedRectangle(cornerRadius: 14))
        .id(stats.profileRevision)
    }
}
