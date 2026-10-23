import SwiftUI
import NostrSDK

struct PhoneZapView: View {
    let stream: Stream
    let client: NostrSDKClient
    @EnvironmentObject private var auth: NostrAuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var payment = PhoneZapModel()
    @State private var amount = 21
    @State private var customAmount = ""
    @State private var comment = ""
    @State private var showSignIn = false
    @State private var walletError: String?
    private let amounts = [21, 100, 420, 1200, 2100, 5000]
    private var chosenAmount: Int? { customAmount.isEmpty ? amount : Int(customAmount) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Make their day.").font(.largeTitle.bold())
                    Text("Send a zap to \(stream.profile?.displayNameOrName ?? "this creator").").foregroundStyle(.secondary)
                    if stream.profile?.lud16?.isEmpty != false {
                        Label("This creator hasn’t set up Lightning yet.", systemImage: "bolt.slash").foregroundStyle(Color.coveGold)
                    } else if !auth.isAuthenticated {
                        Text("Sign in to send a zap with your Nostr identity.")
                        Button("Sign in") { showSignIn = true }.buttonStyle(.borderedProminent)
                    } else if payment.received {
                        Label("Zap received. Thank you!", systemImage: "checkmark.circle.fill")
                            .font(.title2).foregroundStyle(Color.coveAccent).accessibilityIdentifier("phone-zap-received")
                    } else if let invoice = payment.invoice, let url = URL(string: invoice.uri) {
                        Label("\(invoice.sats.formatted()) sats", systemImage: "bolt.fill").font(.title2.bold()).foregroundStyle(Color.coveGold)
                        if let image = PhoneQRCode.make(invoice.uri) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 280).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .frame(maxWidth: .infinity).accessibilityLabel("Lightning invoice QR code")
                        }
                        Button("Open Lightning wallet") {
                            openURL(url) { opened in
                                if !opened { walletError = "No wallet opened this invoice. Copy it into your Lightning wallet or scan the code on another device." }
                            }
                        }.buttonStyle(.borderedProminent)
                        ShareLink("Share invoice", item: invoice.bolt11)
                        Button("Copy invoice") { UIPasteboard.general.string = invoice.bolt11 }
                        Text("Approve the payment in your wallet. Cove waits for the receipt here.").font(.callout).foregroundStyle(.secondary)
                        if let walletError { Text(walletError).foregroundStyle(Color.coveGold) }
                        Button("Change amount") { payment.cancel(); walletError = nil }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                            ForEach(amounts, id: \.self) { value in
                                Button { amount = value; customAmount = "" } label: {
                                    Text("\(value.formatted()) sats").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                                }.buttonStyle(.bordered).tint(value == chosenAmount ? .coveAccent : .coveSecondary)
                            }
                        }
                        TextField("Custom amount in sats", text: $customAmount).keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("phone-zap-custom-amount")
                        TextField("Add a message (optional)", text: $comment, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                        if payment.generating { ProgressView("Preparing your invoice…") }
                        if let error = payment.error { Text(error).foregroundStyle(Color.coveGold) }
                        Button("Prepare invoice") {
                            guard let chosenAmount else { return }
                            payment.generate(stream: stream, sats: chosenAmount, comment: comment, client: client, auth: auth)
                        }.buttonStyle(.borderedProminent)
                            .disabled(payment.generating || chosenAmount == nil || (chosenAmount ?? 0) <= 0)
                            .accessibilityIdentifier("phone-prepare-invoice")
                        Text("You’ll approve payment in your Lightning wallet.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: 620, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively).background(Color.coveBackground)
            .navigationTitle("Send a zap").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $showSignIn) { PhoneSignInView() }
        .onDisappear { payment.cancel() }
    }
}

@MainActor
final class PhoneZapModel: ObservableObject {
    @Published private(set) var invoice: ZapInvoice?
    @Published private(set) var generating = false
    @Published private(set) var received = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var subscription: String?
    private var client: NostrSDKClient?
    private var generation = UUID()

    func generate(stream: Stream, sats: Int, comment: String, client: NostrSDKClient, auth: NostrAuthManager) {
        cancel()
        #if DEBUG
        if CoveUITestSupport.enabled { error = "Invoices are disabled in the offline preview."; return }
        #endif
        self.client = client
        let request = generation
        generating = true
        task = Task {
            do {
                let result = try await ZapRequestGenerator(nostrSDKClient: client, authManager: auth)
                    .generateInvoice(stream: stream, amount: sats, comment: comment, lud16: stream.profile?.lud16 ?? "")
                try Task.checkCancellation()
                guard generation == request else { return }
                client.addRelays(stream.relays)
                let id = "phone-zap-" + UUID().uuidString
                subscription = id
                let owner = self
                client.addZapReceivedCallback(forSubscriptionId: id) { [weak owner] receipt in
                    Task { @MainActor in
                        guard let owner, owner.generation == request, result.matches(receipt) else { return }
                        owner.received = true
                    }
                }
                if let filter = Filter(authors: [result.providerPubkey], kinds: [9735], tags: ["p": [result.recipientPubkey]], limit: 30) {
                    _ = client.subscribe(with: filter, subscriptionId: id, purpose: "zap-receipts")
                }
                invoice = result
                generating = false
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                self.error = error.localizedDescription
                generating = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = UUID()
        if let subscription {
            client?.closeSubscription(subscription)
            client?.removeCallback(forSubscriptionId: subscription)
        }
        subscription = nil
        client = nil
        invoice = nil
        error = nil
        received = false
        generating = false
    }
}
