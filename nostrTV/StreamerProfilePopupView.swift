//
//  StreamerProfilePopupView.swift
//  nostrTV
//
//  Created by Claude Code
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Full-screen popup overlay displaying streamer profile and zap interface
struct StreamerProfilePopupView: View {
    let stream: Stream
    let authManager: NostrAuthManager
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent background - make it focusable to intercept Menu button
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .focusable()
                .onTapGesture { onDismiss() }

            HStack(spacing: 40) {
                // Left panel: Streamer info
                StreamerInfoPanel(stream: stream, onClose: onDismiss)
                    .frame(width: 500)

                // Right panel: Zap interface
                ZapStreamerPanel(
                    stream: stream,
                    authManager: authManager,
                    onClose: onDismiss
                )
                .frame(width: 600)
            }
            .padding(60)
            .background(Color.black)
            .cornerRadius(20)
        }
    }
}

// MARK: - Streamer Info Panel

struct StreamerInfoPanel: View {
    let stream: Stream
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Close button (top-right of panel)
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.card)
            }

            if let profile = stream.profile {
                // Profile picture (large)
                AsyncImage(url: URL(string: profile.picture ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 250, height: 250)
                            .clipShape(Circle())
                    case .failure(_):
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 250, height: 250)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 100))
                                    .foregroundColor(.gray)
                            )
                    case .empty:
                        ProgressView()
                            .frame(width: 250, height: 250)
                    @unknown default:
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 250, height: 250)
                    }
                }

                // Display name
                Text(profile.displayNameOrName)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)

                // Username (@handle)
                if let name = profile.name {
                    Text("@\(name)")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                }

                // NIP-05 verification
                if let nip05 = profile.nip05, !nip05.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 20))
                        Text(nip05)
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                }

                // Bio/About
                if let about = profile.about, !about.isEmpty {
                    Text(about)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(10)
                        .padding(.top, 10)
                }
            } else {
                // No profile available
                VStack(spacing: 20) {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 250, height: 250)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 100))
                                .foregroundColor(.gray)
                        )

                    Text("Anonymous Streamer")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)

                    Text("No profile information available")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                }
            }

            Spacer()
        }
        .padding(30)
    }
}

// MARK: - Zap Streamer Panel

struct ZapStreamerPanel: View {
    let stream: Stream
    let authManager: NostrAuthManager
    let onClose: () -> Void

    @State private var selectedAmount: Int?
    @State private var showQRCode = false
    @State private var invoiceURI: String?
    @State private var isGenerating = false
    @State private var qrCodeImage: UIImage?
    @State private var errorMessage: String?

    @Namespace private var zapNamespace

    // Zap amount options
    private let zapAmounts = [
        (amount: 21, emoji: "☕️", label: "Espresso"),
        (amount: 100, emoji: "☕️", label: "Coffee"),
        (amount: 420, emoji: "🍰", label: "Dessert"),
        (amount: 1200, emoji: "🍕", label: "Lunch"),
        (amount: 2100, emoji: "🍱", label: "Dinner")
    ]

    var body: some View {
        VStack(spacing: 30) {
            // Title
            Text("Buy \(stream.profile?.displayNameOrName ?? "Streamer") Coffee")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            // Check for Lightning address
            if stream.profile?.lud16 == nil || stream.profile?.lud16?.isEmpty == true {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)

                    Text("⚠️ This streamer hasn't set up Lightning zaps")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
            } else if !authManager.isAuthenticated {
                VStack(spacing: 20) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)

                    Text("Please sign in to send authenticated zaps")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
            } else if !showQRCode {
                // Amount selection grid
                VStack(spacing: 20) {
                    ForEach(Array(zapAmounts.enumerated()), id: \.element.amount) { index, option in
                        ZapAmountButton(
                            emoji: option.emoji,
                            amount: option.amount,
                            label: option.label,
                            isSelected: selectedAmount == option.amount,
                            action: { handleAmountSelection(option.amount) }
                        )
                        .prefersDefaultFocus(index == 2, in: zapNamespace)
                    }
                }
                .focusScope(zapNamespace)
            } else {
                // QR Code display
                VStack(spacing: 20) {
                    // Amount display
                    HStack(spacing: 8) {
                        Text("⚡️")
                            .font(.system(size: 48))
                        Text("\(selectedAmount ?? 0) sats")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.yellow)
                    }

                    if isGenerating {
                        ProgressView()
                            .scaleEffect(2.0)
                        Text("Generating QR code...")
                            .font(.system(size: 24))
                            .foregroundColor(.gray)
                    } else if let error = errorMessage {
                        // Error state
                        VStack(spacing: 20) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundColor(.red)

                            Text(error)
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)

                            Button("Try Again") {
                                errorMessage = nil
                                if let amount = selectedAmount {
                                    handleAmountSelection(amount)
                                }
                            }
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 200, height: 60)
                            .background(Color.blue)
                            .cornerRadius(10)
                            .buttonStyle(.card)
                        }
                    } else if let qrImage = qrCodeImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 500, height: 500)
                            .background(Color.white)
                            .cornerRadius(20)
                            .shadow(color: .yellow.opacity(0.3), radius: 20)
                    }

                    // Instructions
                    Text("Scan to send zap")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)

                    // Back button (only show if no error)
                    if errorMessage == nil {
                        Button(action: {
                            showQRCode = false
                            selectedAmount = nil
                            qrCodeImage = nil
                            invoiceURI = nil
                            errorMessage = nil
                        }) {
                            Text("Back")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .frame(width: 200, height: 60)
                                .background(Color.gray)
                                .cornerRadius(10)
                        }
                        .buttonStyle(.card)
                    }
                }
            }

            Spacer()
        }
        .padding(30)
    }

    private func handleAmountSelection(_ amount: Int) {
        selectedAmount = amount
        showQRCode = true
        isGenerating = true

        guard let lud16 = stream.profile?.lud16, !lud16.isEmpty else {
            // Show error: No Lightning address
            Task { @MainActor in
                errorMessage = "This streamer hasn't set up Lightning zaps"
                isGenerating = false
                invoiceURI = nil
            }
            return
        }

        Task {
            do {
                // Get NostrSDKClient instance
                let nostrSDKClient = try NostrSDKClient()

                // Create zap request generator with authManager
                let generator = ZapRequestGenerator(
                    nostrSDKClient: nostrSDKClient,
                    authManager: authManager
                )

                // Generate zap request (will use authManager for signing if authenticated)
                let uri = try await generator.generateZapRequest(
                    stream: stream,
                    amount: amount,
                    comment: "Sent from nostrTV",
                    lud16: lud16,
                    keyPair: nil  // Will use authManager for signing
                )

                // Generate QR code
                let qrImage = await generateQRCode(from: uri)

                await MainActor.run {
                    invoiceURI = uri
                    qrCodeImage = qrImage
                    isGenerating = false
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
                let targetDimension: CGFloat = 500
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
}

// MARK: - Zap Amount Button

struct ZapAmountButton: View {
    let emoji: String
    let amount: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isFocused) var isFocused

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Text(emoji)
                    .font(.system(size: 40))

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(amount) sats")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                    Text(label)
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                }

                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(isFocused ? Color.yellow.opacity(0.4) : (isSelected ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.3)))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? Color.yellow : (isSelected ? Color.yellow.opacity(0.5) : Color.clear), lineWidth: isFocused ? 4 : 3)
            )
        }
        .buttonStyle(.card)
    }
}
