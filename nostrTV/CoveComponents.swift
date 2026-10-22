import SwiftUI

/// Shared TV controls keep focus distinct from selection and respect reduced motion.
struct CoveButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        CoveButtonSurface(configuration: configuration, prominent: prominent, selected: selected)
    }
}

private struct CoveButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let selected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: 24, weight: .semibold))
            .frame(minHeight: 36)
            .padding(.horizontal, 26).padding(.vertical, 18)
            .foregroundStyle(prominent ? Color.coveBackground : Color.white)
            .background(prominent ? Color.coveAccent : (selected ? Color.coveOverlay : Color.coveSurface))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(isFocused ? Color.white : .clear, lineWidth: 4).padding(-6))
            .scaleEffect(isFocused && !reduceMotion ? 1.035 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
    }
}

struct CoveAvatar: View {
    let profile: Profile?
    var size: CGFloat = 48
    var body: some View {
        let urls = ArtworkSource.urls([profile?.picture])
        CachedAsyncImage(urls: urls, preserveImageFor: urls.isEmpty ? nil : profile?.pubkey.lowercased()) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(Color.coveAccent.opacity(0.16))
                .overlay(Text(String((profile?.displayNameOrName ?? "?").prefix(1))).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(Color.coveAccent))
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct CoveArtwork: View {
    let urls: [URL]
    let streamID: String
    var body: some View {
        GeometryReader { geometry in
            CachedAsyncImage(urls: urls, preserveImageFor: streamID) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    LinearGradient(colors: [.coveSurface, .coveOverlay, .coveBackground], startPoint: .topTrailing, endPoint: .bottomLeading)
                    Image(systemName: "play.rectangle").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Color.coveAccent.opacity(0.35))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
    }
}

struct CoveLiveBadge: View {
    var live = true
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(live ? Color.coveGold : .coveSecondary).frame(width: 9, height: 9)
            Text(live ? "LIVE" : "ENDED").font(.system(size: 18, weight: .bold)).tracking(2)
        }.foregroundStyle(.white)
    }
}

struct CoveEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: symbol).font(.system(size: 64, weight: .light)).foregroundStyle(Color.coveAccent)
            Text(title).font(.coveSection)
            Text(message).font(.coveBody).foregroundStyle(Color.coveSecondary).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 1000, alignment: .leading)
    }
}

/// Keep visible slots stable while relay events update counts or discovery order.
struct CoveStreamOrder {
    private(set) var ids: [String] = []
    mutating func reconcile(_ incoming: [String]) {
        let available = Set(incoming)
        ids.removeAll { !available.contains($0) }
        var seen = Set(ids)
        ids.append(contentsOf: incoming.filter { seen.insert($0).inserted })
    }
}
