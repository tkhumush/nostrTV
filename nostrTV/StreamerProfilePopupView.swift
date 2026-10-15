import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import NostrSDK

struct StreamerProfilePopupView: View {
    let stream: Stream
    let authManager: NostrAuthManager
    let nostrSDKClient: NostrSDKClient
    let onDismiss: () -> Void
    var startsWithZap = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.7).ignoresSafeArea().onTapGesture(perform: onDismiss)
            StreamerSideMenu(stream: stream, authManager: authManager, nostrSDKClient: nostrSDKClient,
                             onClose: onDismiss, startsWithZap: startsWithZap)
                .frame(width: 620).frame(maxHeight: .infinity)
                .background(Color.coveSurface)
        }.accessibilityAddTraits(.isModal)
    }
}

struct StreamerSideMenu: View {
    let stream: Stream
    @ObservedObject var authManager: NostrAuthManager
    let nostrSDKClient: NostrSDKClient
    let onClose: () -> Void
    var startsWithZap = false
    @State private var selectingZap = false
    @State private var selectedAmount: Int?
    @State private var showQRCode = false
    @State private var invoiceURI: String?
    @State private var isGenerating = false
    @State private var qrCodeImage: UIImage?
    @State private var errorMessage: String?
    @State private var zapReceived = false
    @State private var generatedInvoice: String?
    @State private var zapSubscriptionId: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var generation = UUID()
    @FocusState private var focusedMenuItem: MenuFocus?
    @Namespace private var menuNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    enum MenuFocus: Hashable { case closeButton, zap, zapAmount(Int), qrBackButton, qrTryAgain }
    private let amounts = [21, 100, 420, 1200, 2100, 5000]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Text(selectingZap ? "A LITTLE APPRECIATION" : "INDEPENDENT CREATOR")
                            .font(.system(size: 17, weight: .bold)).tracking(2).foregroundStyle(Color.coveAccent)
                        Spacer()
                        Button(action: onClose) { Image(systemName: "xmark") }
                            .buttonStyle(CoveButtonStyle()).focused($focusedMenuItem, equals: .closeButton)
                            .prefersDefaultFocus(in: menuNamespace).id(MenuFocus.closeButton)
                            .accessibilityLabel("Close creator panel").accessibilityIdentifier("creator-close")
                    }
                    if selectingZap { zapContent } else { creatorContent }
                }.padding(45)
            }
            .focusScope(menuNamespace).focusSection()
            .onChange(of: focusedMenuItem) { _, item in
                if let item { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(item, anchor: .center) } }
            }
            .onAppear { selectingZap = startsWithZap; focusedMenuItem = .closeButton }
            .onDisappear { cleanupZapState() }
            .onChange(of: showQRCode) { _, showing in focusedMenuItem = showing ? .qrBackButton : .closeButton }
            .onChange(of: errorMessage) { _, error in if error != nil { focusedMenuItem = .qrTryAgain } }
            .onExitCommand {
                if showQRCode { cleanupZapState() }
                else if selectingZap && !startsWithZap { selectingZap = false; focusedMenuItem = .zap }
                else { onClose() }
            }
        }
    }

    private var creatorContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            CoveAvatar(profile: stream.profile, size: 120)
            Text(stream.profile?.displayNameOrName ?? "Independent creator").font(.coveSection).lineLimit(3)
            if let about = stream.profile?.about, !about.isEmpty {
                Text(about).font(.coveBody).foregroundStyle(Color.coveSecondary).lineLimit(6)
            }
            if let pubkey = stream.pubkey,
               authManager.followList.contains(where: { $0.lowercased() == pubkey.lowercased() }) {
                Label("Following", systemImage: "checkmark").font(.coveBody).foregroundStyle(Color.coveAccent)
            } else {
                Text("Follow this creator in your Nostr app to see them in Following.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
            }
            Divider()
            HStack(spacing: 40) {
                VStack(alignment: .leading, spacing: 8) { Text(stream.viewerCount.formatted()).font(.coveSubheading); Text("watching now").font(.coveCaption).foregroundStyle(Color.coveSecondary) }
                VStack(alignment: .leading, spacing: 8) { Text(stream.category).font(.coveSubheading); Text("on the air").font(.coveCaption).foregroundStyle(Color.coveSecondary) }
            }
            Button { selectingZap = true; focusedMenuItem = .closeButton } label: {
                Label("Send a zap", systemImage: "bolt.fill").frame(maxWidth: .infinity)
            }.buttonStyle(CoveButtonStyle(prominent: true)).focused($focusedMenuItem, equals: .zap).id(MenuFocus.zap)
        }
    }

    @ViewBuilder private var zapContent: some View {
        Text("Make their day.").font(.coveSection)
        Text("Send a zap to \(stream.profile?.displayNameOrName ?? "this creator").").font(.coveBody).foregroundStyle(Color.coveSecondary)
        if stream.profile?.lud16?.isEmpty != false {
            Label("This creator hasn’t set up Lightning yet.", systemImage: "bolt.slash").font(.coveBody).foregroundStyle(Color.coveGold)
        } else if !authManager.isAuthenticated {
            Text("Sign in from Your space to send zaps.").font(.coveBody).foregroundStyle(Color.coveSecondary)
        } else if !showQRCode {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 22) {
                ForEach(amounts, id: \.self) { amount in
                    Button { handleAmountSelection(amount) } label: {
                        VStack(spacing: 8) { Text(amount.formatted()).font(.coveSubheading); Text("sats").font(.coveCaption) }.frame(maxWidth: .infinity)
                    }.buttonStyle(CoveButtonStyle()).focused($focusedMenuItem, equals: .zapAmount(amount)).id(MenuFocus.zapAmount(amount))
                }
            }
            Text("Choose an amount, then scan with your Lightning wallet.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
        } else {
            VStack(spacing: 24) {
                Label("\((selectedAmount ?? 0).formatted()) sats", systemImage: "bolt.fill").font(.coveSubheading).foregroundStyle(Color.coveGold)
                if zapReceived {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 90)).foregroundStyle(Color.coveAccent)
                    Text("Zap received. Thank you!").font(.coveSubheading)
                } else if isGenerating {
                    ProgressView().tint(.coveAccent)
                    Text("Preparing your invoice…").font(.coveCaption)
                } else if let errorMessage {
                    Text(errorMessage).font(.coveCaption).foregroundStyle(Color.coveGold)
                    Button("Try again") { if let selectedAmount { handleAmountSelection(selectedAmount) } }
                        .buttonStyle(CoveButtonStyle(prominent: true)).focused($focusedMenuItem, equals: .qrTryAgain).id(MenuFocus.qrTryAgain)
                } else if let qrCodeImage {
                    Image(uiImage: qrCodeImage).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 360, height: 360).padding(18).background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
                    Text("Scan with your Lightning wallet").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                }
                Button("Change amount") { cleanupZapState() }.buttonStyle(CoveButtonStyle())
                    .focused($focusedMenuItem, equals: .qrBackButton).id(MenuFocus.qrBackButton)
            }.frame(maxWidth: .infinity)
        }
    }

    private func handleAmountSelection(_ amount: Int) {
        cleanupZapState()
        let requestID = UUID()
        generation = requestID
        selectedAmount = amount
        showQRCode = true
        isGenerating = true

        guard let lud16 = stream.profile?.lud16, !lud16.isEmpty else {
            Task { @MainActor in
                errorMessage = "This streamer hasn't set up Lightning zaps"
                isGenerating = false
                invoiceURI = nil
            }
            return
        }

        generationTask = Task {
            do {
                // Use the shared app-level client instead of creating a new one.
                // This prevents a per-zap relay pool from leaking and ensures
                // zap receipts arrive on the same connection used by chat/zaps.
                let generator = ZapRequestGenerator(
                    nostrSDKClient: nostrSDKClient,
                    authManager: authManager
                )

                let uri = try await generator.generateZapRequest(
                    stream: stream,
                    amount: amount,
                    comment: "Sent from Cove",
                    lud16: lud16
                )

                try Task.checkCancellation()
                let qrImage = await generateQRCode(from: uri)
                try Task.checkCancellation()

                // Extract just the invoice string (without "lightning:" prefix)
                let invoice = uri.replacingOccurrences(of: "lightning:", with: "")

                await MainActor.run {
                    guard generation == requestID, showQRCode else { return }
                    guard let qrImage else {
                        errorMessage = "Couldn’t render the invoice. Please try again."
                        isGenerating = false
                        return
                    }
                    invoiceURI = uri
                    generatedInvoice = invoice
                    qrCodeImage = qrImage
                    isGenerating = false

                    // Subscribe to zap receipts on the shared client
                    subscribeToZapReceipts(invoice: invoice)
                }
            } catch let error as ZapRequestError {
                await MainActor.run {
                    guard generation == requestID, showQRCode else { return }
                    print("❌ Failed to generate zap: \(error.localizedDescription)")
                    switch error {
                    case .noSigningMethodAvailable:
                        errorMessage = "Please sign in to send zaps"
                    case .invalidLightningAddress:
                        errorMessage = "Invalid Lightning address"
                    case .serverError(let msg):
                        errorMessage = "Server error: \(msg)"
                    case .missingCallback:
                        errorMessage = "Lightning service error"
                    case .missingInvoice:
                        errorMessage = "Failed to generate invoice"
                    default:
                        errorMessage = error.localizedDescription
                    }
                    isGenerating = false
                    invoiceURI = nil
                }
            } catch {
                await MainActor.run {
                    guard generation == requestID, showQRCode else { return }
                    print("❌ Failed to generate zap: \(error.localizedDescription)")
                    errorMessage = "Failed to generate QR code. Please try again."
                    isGenerating = false
                    invoiceURI = nil
                }
            }
        }
    }

    private func generateQRCode(from string: String) async -> UIImage? {
        return await Task.detached(priority: .userInitiated) {
            let context = CIContext()
            let filter = CIFilter.qrCodeGenerator()
            let data = Data(string.utf8)

            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("Q", forKey: "inputCorrectionLevel")

            if let outputImage = filter.outputImage {
                let targetDimension: CGFloat = 400
                let scaleX = targetDimension / outputImage.extent.size.width
                let scaleY = targetDimension / outputImage.extent.size.height
                let transformedImage = outputImage.transformed(
                    by: CGAffineTransform(scaleX: scaleX, y: scaleY)
                )

                if let cgImage = context.createCGImage(
                    transformedImage,
                    from: transformedImage.extent
                ) {
                    return UIImage(cgImage: cgImage)
                }
            }

            return nil
        }.value
    }

    private func subscribeToZapReceipts(invoice: String) {
        print("📡 Subscribing to zap receipts for invoice: \(invoice.prefix(20))...")

        // Subscribe to kind 9735 (zap receipt) events on the shared client
        guard let filter = Filter(kinds: [9735], limit: 100) else {
            print("❌ Failed to create zap receipt filter")
            return
        }

        let subscriptionId = nostrSDKClient.subscribe(with: filter, purpose: "zap-receipts")
        zapSubscriptionId = subscriptionId
        print("✅ Subscribed to zap receipts with ID: \(subscriptionId)")

        // Set up callback for zap receipts, keyed by subscription ID for proper cleanup
        nostrSDKClient.addZapReceivedCallback(forSubscriptionId: subscriptionId) { zapComment in
            Task { @MainActor [self] in
                guard generatedInvoice == invoice, showQRCode else { return }
                print("📨 Received zap receipt")

                // Check if this receipt matches our invoice
                if let bolt11 = zapComment.bolt11 {
                    print("   Receipt invoice: \(bolt11.prefix(20))...")
                    print("   Our invoice:     \(invoice.prefix(20))...")

                    if bolt11 == invoice {
                        print("✅ Zap receipt matched! Payment received!")

                        // Update UI to show success
                        self.zapReceived = true

                        // Auto-dismiss after 3 seconds
                        let completedGeneration = generation
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            await MainActor.run {
                                guard generation == completedGeneration else { return }
                                self.cleanupZapState()
                            }
                        }
                    }
                }
            }
        }
    }

    private func cleanupZapState() {
        print("🧹 Cleaning up zap state")
        generationTask?.cancel()
        generationTask = nil
        generation = UUID()
        isGenerating = false
        showQRCode = false
        selectedAmount = nil
        qrCodeImage = nil
        invoiceURI = nil
        errorMessage = nil
        zapReceived = false
        generatedInvoice = nil

        // Close the zap receipt subscription and remove its callback on the shared client
        if let subId = zapSubscriptionId {
            nostrSDKClient.closeSubscription(subId)
            nostrSDKClient.removeCallback(forSubscriptionId: subId)
            zapSubscriptionId = nil
        }
    }
}
