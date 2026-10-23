import SwiftUI
import NostrSDK
import CoreImage.CIFilterBuiltins

struct PhoneCreatorView: View {
    let stream: Stream
    let client: NostrSDKClient
    @EnvironmentObject private var auth: NostrAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var showZap = false
    private var profile: Profile? { stream.pubkey.flatMap { client.getProfile(for: $0) } ?? stream.profile }
    private var following: Bool { stream.pubkey.map { key in auth.followList.contains { $0.caseInsensitiveCompare(key) == .orderedSame } } ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CoveAvatar(profile: profile, size: 100)
                    Text(profile?.displayNameOrName ?? "Independent creator").font(.largeTitle.bold())
                    if let name = profile?.name { Text("@\(name)").foregroundStyle(.secondary) }
                    if let about = profile?.about, !about.isEmpty { Text(about).textSelection(.enabled) }
                    if following { Label("Following", systemImage: "checkmark.circle.fill").foregroundStyle(Color.coveAccent) }
                    else { Text("Follow this creator in your Nostr app to bring them into Following.").font(.callout).foregroundStyle(.secondary) }
                    if let pubkey = stream.pubkey, let npub = PublicKey(hex: pubkey)?.npub, let url = URL(string: "nostr:\(npub)") {
                        Link("View in your Nostr app", destination: url)
                        ShareLink("Share profile", item: url)
                    }
                    Divider()
                    Label(stream.isLive ? "\(stream.viewerCount.formatted()) watching" : "Replay", systemImage: "play.rectangle")
                    Text(stream.category).foregroundStyle(.secondary)
                    Button { showZap = true } label: { Label("Send a zap", systemImage: "bolt.fill").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).tint(.coveAccent).foregroundStyle(Color.coveBackground)
                        .accessibilityIdentifier("phone-creator-zap")
                }.frame(maxWidth: 620, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }
            .background(Color.coveBackground).navigationTitle("Creator").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $showZap) { PhoneZapView(stream: stream.attachingProfile(profile), client: client) }
    }
}

enum PhoneQRCode {
    static func make(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
