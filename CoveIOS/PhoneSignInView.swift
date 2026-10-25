import SwiftUI
import CoreImage.CIFilterBuiltins

struct PhoneSignInView: View {
    @EnvironmentObject private var auth: NostrAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var showRemoteSigner = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Bring your identity").font(.title2.bold())
                    Text("Connect your Nostr identity to follow your people, chat, and send zaps.").foregroundStyle(.secondary)
                }
                Section {
                    Button { showRemoteSigner = true } label: {
                        Label("Connect a remote signer", systemImage: "key.horizontal")
                    }.accessibilityIdentifier("phone-remote-sign-in")
                    NavigationLink { PhoneNsecSignInView() } label: { Label("Use a private key", systemImage: "lock") }
                        .accessibilityIdentifier("phone-key-sign-in")
                } footer: { Text("A remote signer keeps your private key in the signer you choose.") }
            }
            .scrollContentBackground(.hidden).background(Color.coveBackground)
            .navigationTitle("Sign in").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .sheet(isPresented: $showRemoteSigner) { PhoneRemoteSignInView() }
        .onChange(of: auth.isAuthenticated) { _, authenticated in if authenticated { dismiss() } }
    }
}

private struct PhoneNsecSignInView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var auth: NostrAuthManager
    @State private var nsec = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            Section {
                SecureField("nsec1…", text: $nsec).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive().accessibilityIdentifier("phone-nsec")
                Text("Your key is saved in this device’s Keychain and used to sign your messages.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Nostr private key") }
            if let error { Section { Text(error).foregroundStyle(Color.coveGold) } }
            Section {
                Button("Sign in") {
                    let submittedKey = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
                    nsec = ""
                    busy = true
                    error = nil
                    Task { @MainActor in
                        defer { busy = false }
                        #if DEBUG
                        if CoveUITestSupport.enabled { error = "Sign-in is disabled in the offline preview."; return }
                        #endif
                        do { try await auth.authenticateWithNsec(submittedKey) }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy || nsec.isEmpty)
                    .accessibilityIdentifier("phone-nsec-submit")
                if busy { ProgressView("Signing in…") }
            }
        }
        .scrollContentBackground(.hidden).background(Color.coveBackground).navigationTitle("Private key")
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in nsec = "" }
        .onDisappear { nsec = "" }
        .onChange(of: scenePhase) { _, phase in if phase != .active { nsec = "" } }
    }
}

/// Reuse the NIP-46 handshake with a link for this phone and a QR for another device.
private struct PhoneRemoteSignInView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var auth: NostrAuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var signer = NostrBunkerClient(keyManager: NostrKeyManager.shared)
    @State private var uri: URL?
    @State private var qr: UIImage?
    @State private var error: String?
    @State private var handedOff = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Bring your identity").font(.largeTitle.bold())
                    Text("Open the connection in a compatible NIP-46 signer, or scan the code from another device. Approve it there, then return to Cove.")
                        .foregroundStyle(.secondary)
                    if scenePhase == .active, let qr {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 280).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Nostr signer connection QR code")
                    }
                    if signer.connectionState == .waitingForScan, let uri {
                        Button("Open signer") {
                            openURL(uri) { opened in
                                if !opened { error = "No app opened this link. Share the connection with your signer or scan the code on another device." }
                            }
                        }.buttonStyle(.borderedProminent).tint(.coveAccent).foregroundStyle(Color.coveBackground)
                        ShareLink("Share connection", item: uri)
                    }
                    if let error {
                        Text(error).foregroundStyle(Color.coveGold)
                        Text("Close this sheet and sign in again to start a new connection.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView(uri == nil ? "Preparing connection…" : "Waiting for your signer…")
                    }
                }.padding(24)
            }
            .background(Color.coveBackground)
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { await connect() }
        .onDisappear {
            uri = nil
            qr = nil
            if !handedOff { signer.disconnect() }
        }
    }

    @MainActor
    private func connect() async {
        #if DEBUG
        if CoveUITestSupport.enabled {
            error = "Sign-in is disabled in the offline preview."
            return
        }
        #endif
        do {
            // A new pairing always gets a new client identity. Session restoration uses the saved key.
            try NostrKeyManager.shared.generateEphemeralKeyPair()
            guard let clientPubkey = NostrKeyManager.shared.publicKeyHex else { throw BunkerError.notConnected }
            let connection = BunkerURIComponents(clientPubkey: clientPubkey,
                relays: ["wss://relay.primal.net", "wss://relay.damus.io", "wss://bucket.coracle.social"],
                secret: UUID().uuidString, metadata: ["name": "Cove", "url": "https://nostrtv.app"])
                .toNostrConnectURI()
            uri = URL(string: connection)
            qr = PhoneQRCode.make(connection)
            try await signer.waitForSignerConnection(bunkerURI: connection)
            try Task.checkCancellation()
            let pubkey = try await signer.getPublicKey()
            try Task.checkCancellation()
            try await auth.authenticateWithBunker(bunkerClient: signer, userPubkey: pubkey)
            guard auth.isAuthenticated else { throw BunkerError.connectionFailed(auth.errorMessage ?? "Could not sign in") }
            handedOff = true
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
