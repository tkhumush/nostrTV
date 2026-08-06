//
//  StreamerProfilePopupView.swift
//  nostrTV
//
//  Created by Claude Code
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import NostrSDK

/// Side menu displaying streamer profile and zap interface
struct StreamerProfilePopupView: View {
    let stream: Stream
    let authManager: NostrAuthManager
    let nostrSDKClient: NostrSDKClient
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Side menu panel
            StreamerSideMenu(
                stream: stream,
                authManager: authManager,
                nostrSDKClient: nostrSDKClient,
                onClose: onDismiss
            )
            .frame(width: 600)
            .background(Color.coveBackground)

            Spacer()
        }
        .transition(.move(edge: .leading))
        .background(
            Color.coveBackground.opacity(0.7)
                .ignoresSafeArea()
                // Gives the dimmed area a stable hit region for the tap-to-dismiss
                // gesture. This does not affect focus — the chrome behind is kept out
                // of the focus engine by `.disabled` in VideoPlayerView, not here.
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
        )
    }
}

// MARK: - Streamer Side Menu

struct StreamerSideMenu: View {
    let stream: Stream
    let authManager: NostrAuthManager
    let nostrSDKClient: NostrSDKClient
    let onClose: () -> Void

    @State private var selectedAmount: Int?
    @State private var showQRCode = false
    @State private var invoiceURI: String?
    @State private var isGenerating = false
    @State private var qrCodeImage: UIImage?
    @State private var errorMessage: String?
    @State private var zapReceived = false
    @State private var generatedInvoice: String?  // Store just the invoice string for matching
    @State private var zapSubscriptionId: String?

    /// Controls inside the side menu that can hold focus.
    ///
    /// The menu owns its own focus state rather than sharing VideoPlayerView's:
    /// `zIndex` only affects draw and hit-test order, so without a dedicated scope the
    /// tvOS focus engine never moves focus into this overlay and the Siri Remote
    /// cannot reach these controls.
    enum MenuFocus: Hashable {
        case closeButton
        case zapAmount(Int)
        case qrBackButton
        case qrTryAgain
    }

    @Namespace private var menuNamespace
    @FocusState private var focusedMenuItem: MenuFocus?

    // Zap amount options
    private let zapAmounts = [
        (amount: 21, emoji: "☕️", label: "Espresso"),
        (amount: 100, emoji: "☕️", label: "Coffee"),
        (amount: 420, emoji: "🍰", label: "Dessert"),
        (amount: 1200, emoji: "🍕", label: "Lunch"),
        (amount: 2100, emoji: "🍱", label: "Dinner")
    ]

    var body: some View {
        // Scrolling, but driven explicitly.
        //
        // #36 removed the ScrollView because it competed for focus, on the assumption
        // the content fit the panel. It does not — with all five zap amounts listed the
        // menu is taller than the screen and the last row was clipped off the bottom.
        //
        // The answer is not to drop scrolling but to stop relying on the focus engine
        // to do it: every focusable row carries an `.id`, and we scroll to whichever
        // one currently holds focus.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    // Close button - native Liquid Glass style
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 40))
                                // .card gives the focus engine a real focusable target, and
                                // the explicit frame keeps it above the 44pt minimum that a
                                // bare Image would fall under.
                                .frame(width: 60, height: 60)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.card)
                        .focused($focusedMenuItem, equals: .closeButton)
                        .prefersDefaultFocus(in: menuNamespace)
                        .id(MenuFocus.closeButton)
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 30)

                    // Profile Section
                    VStack(alignment: .center, spacing: 20) {
                        if let profile = stream.profile {
                            // Profile picture
                            AsyncImage(url: URL(string: profile.picture ?? "")) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 200, height: 200)
                                        .clipShape(Circle())
                                case .failure(_):
                                    Circle()
                                        .fill(Color.coveOverlay)
                                        .frame(width: 200, height: 200)
                                        .overlay(
                                            Image(systemName: "person.fill")
                                                .font(.system(size: 80))
                                                .foregroundColor(.gray)
                                        )
                                case .empty:
                                    ProgressView()
                                        .frame(width: 200, height: 200)
                                @unknown default:
                                    Circle()
                                        .fill(Color.coveOverlay)
                                        .frame(width: 200, height: 200)
                                }
                            }

                            // Display name
                            Text(profile.displayNameOrName)
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.white)

                            // Username (@handle)
                            if let name = profile.name {
                                Text("@\(name)")
                                    .font(.system(size: 20))
                                    .foregroundColor(.gray)
                            }

                            // NIP-05 verification
                            if let nip05 = profile.nip05, !nip05.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.coveAccent)
                                        .font(.system(size: 18))
                                    Text(nip05)
                                        .font(.system(size: 18))
                                        .foregroundColor(.coveAccent)
                                }
                            }

                            // Bio/About - hidden when QR code is showing to make room
                            if let about = profile.about, !about.isEmpty, !showQRCode {
                                Text(about)
                                    .font(.system(size: 18))
                                    .foregroundColor(.white.opacity(0.8))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(6)
                                    .padding(.horizontal, 20)
                            }
                        } else {
                            // No profile available
                            Circle()
                                .fill(Color.coveOverlay)
                                .frame(width: 200, height: 200)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 80))
                                        .foregroundColor(.gray)
                                )

                            Text("Anonymous Streamer")
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 30)

                    Divider()
                        .background(Color.coveOverlay)
                        .padding(.horizontal, 30)

                    // Zap Section
                    VStack(alignment: .leading, spacing: 20) {
                        Text("\(CoveCopy.zapAction) to \(stream.profile?.displayNameOrName ?? "Streamer")")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 30)

                        if stream.profile?.lud16 == nil || stream.profile?.lud16?.isEmpty == true {
                            VStack(spacing: 15) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 40))
                                    .foregroundColor(.coveGold)

                                Text("This streamer hasn't set up Lightning yet")
                                    .font(.coveCaption)
                                    .foregroundColor(.coveGold)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 30)
                        } else if !authManager.isAuthenticated {
                            VStack(spacing: 15) {
                                Image(systemName: "person.crop.circle.badge.exclamationmark")
                                    .font(.system(size: 40))
                                    .foregroundColor(.coveSecondary)

                                Text("Sign in to send zaps")
                                    .font(.coveCaption)
                                    .foregroundColor(.coveSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 30)
                        } else if !showQRCode {
                            // Zap amount buttons
                            VStack(spacing: 15) {
                                ForEach(zapAmounts, id: \.amount) { option in
                                    ZapAmountButton(
                                        emoji: option.emoji,
                                        amount: option.amount,
                                        label: option.label,
                                        isSelected: selectedAmount == option.amount,
                                        action: { handleAmountSelection(option.amount) }
                                    )
                                    .focused($focusedMenuItem, equals: .zapAmount(option.amount))
                                    .id(MenuFocus.zapAmount(option.amount))
                                }
                            }
                            .padding(.horizontal, 30)
                        } else {
                            // QR Code display
                            VStack(spacing: 20) {
                                // Amount display
                                HStack(spacing: 8) {
                                    Text("⚡️")
                                        .font(.system(size: 36))
                                    Text("\(selectedAmount ?? 0) sats")
                                        .font(.system(size: 28, weight: .bold))
                                        .foregroundColor(.coveGold)
                                }

                                if zapReceived {
                                    // Success state - Zap received!
                                    VStack(spacing: 20) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 100))
                                            .foregroundColor(.coveAccent)
                                            .scaleEffect(1.0)
                                            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: zapReceived)

                                        Text("Zap Received!")
                                            .font(.system(size: 36, weight: .bold, design: .rounded))
                                            .foregroundColor(.coveGold)

                                        Text("Thank you for supporting \(stream.profile?.displayNameOrName ?? "the streamer")!")
                                            .font(.system(size: 20))
                                            .foregroundColor(.white.opacity(0.8))
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 20)
                                    }
                                    .padding(.vertical, 60)
                                } else if isGenerating {
                                    ProgressView()
                                        .scaleEffect(1.5)
                                    Text(CoveCopy.generatingQR)
                                        .font(.coveCaption)
                                        .foregroundColor(.coveSecondary)
                                } else if let error = errorMessage {
                                    // Error state
                                    VStack(spacing: 15) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.system(size: 40))
                                            .foregroundColor(.coveGold)

                                        Text(error)
                                            .font(.coveCaption)
                                            .foregroundColor(.white)
                                            .multilineTextAlignment(.center)

                                        Button("Try Again") {
                                            errorMessage = nil
                                            if let amount = selectedAmount {
                                                handleAmountSelection(amount)
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.coveAccent)
                                        .font(.system(size: 20))
                                        .controlSize(.large)
                                        .focused($focusedMenuItem, equals: .qrTryAgain)
                                        .id(MenuFocus.qrTryAgain)
                                    }
                                } else if let qrImage = qrCodeImage {
                                    Image(uiImage: qrImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 400, height: 400)
                                        .background(Color.white)
                                        .cornerRadius(20)
                                        .shadow(color: .coveGold.opacity(0.3), radius: 15)
                                }

                                // Instructions (hide when zap received)
                                if !zapReceived {
                                    Text(CoveCopy.scanToZap)
                                        .font(.coveCaption)
                                        .foregroundColor(.coveSecondary)
                                }

                                // Back button (hide when zap received - will auto-dismiss)
                                if errorMessage == nil && !zapReceived {
                                    Button("Back", action: {
                                        cleanupZapState()
                                    })
                                    .buttonStyle(.bordered)
                                    .font(.system(size: 20))
                                    .controlSize(.large)
                                    .focused($focusedMenuItem, equals: .qrBackButton)
                                    .id(MenuFocus.qrBackButton)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 30)
                            .offset(y: -15)  // Move QR code section up by 15 pixels
                        }
                    }

                    Spacer(minLength: 20)
                }
            }
            // Treat the menu as a single focus region, and resolve the close button's
            // `prefersDefaultFocus(in:)` against this namespace.
            //
            // `focusScope` is not a barrier and does not hold focus here; it works only
            // because VideoPlayerView disables the chrome while this menu is up, leaving
            // nothing else on screen for the focus engine to choose.
            .focusSection()
            .focusScope(menuNamespace)
            // Keep the focused row on screen. Without this the bottom zap amounts sit
            // below the fold and cannot be read while they are selected.
            .onChange(of: focusedMenuItem) { _, item in
                guard let item else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(item, anchor: .center)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if focusedMenuItem == nil {
                        focusedMenuItem = .closeButton
                    }
                }
            }
            // Entering and leaving the QR state swaps which controls exist, so move focus
            // explicitly instead of leaving it on a control that just disappeared.
            .onChange(of: showQRCode) { _, isShowingQR in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedMenuItem = isShowingQR ? .qrBackButton : .closeButton
                }
            }
            .onChange(of: errorMessage) { _, message in
                guard message != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedMenuItem = .qrTryAgain
                }
            }
        }
    }

    private func handleAmountSelection(_ amount: Int) {
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

        Task {
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

                let qrImage = await generateQRCode(from: uri)

                // Extract just the invoice string (without "lightning:" prefix)
                let invoice = uri.replacingOccurrences(of: "lightning:", with: "")

                await MainActor.run {
                    invoiceURI = uri
                    generatedInvoice = invoice
                    qrCodeImage = qrImage
                    isGenerating = false

                    // Subscribe to zap receipts on the shared client
                    subscribeToZapReceipts(invoice: invoice)
                }
            } catch let error as ZapRequestError {
                await MainActor.run {
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
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            await MainActor.run {
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


// MARK: - Zap Amount Button

struct ZapAmountButton: View {
    let emoji: String
    let amount: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Text(emoji)
                    .font(.system(size: 40))

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(amount) sats")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(label)
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .coveGold : .coveSecondary)
        .controlSize(.large)
    }
}
