//
//  StreamerProfilePopupView.swift
//  nostrTV
//
//  Created by Claude Code
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Side menu displaying streamer profile and zap interface
struct StreamerProfilePopupView: View {
    let stream: Stream
    let authManager: NostrAuthManager
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Side menu panel
            StreamerSideMenu(
                stream: stream,
                authManager: authManager,
                onClose: onDismiss
            )
            .frame(width: 600)
            .background(Color.black)

            Spacer()
        }
        .transition(.move(edge: .leading))
        .background(
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
        )
    }
}

// MARK: - Streamer Side Menu

struct StreamerSideMenu: View {
    let stream: Stream
    let authManager: NostrAuthManager
    let onClose: () -> Void

    @State private var selectedAmount: Int?
    @State private var showQRCode = false
    @State private var invoiceURI: String?
    @State private var isGenerating = false
    @State private var qrCodeImage: UIImage?
    @State private var errorMessage: String?

    // Zap amount options
    private let zapAmounts = [
        (amount: 21, emoji: "☕️", label: "Espresso"),
        (amount: 100, emoji: "☕️", label: "Coffee"),
        (amount: 420, emoji: "🍰", label: "Dessert"),
        (amount: 1200, emoji: "🍕", label: "Lunch"),
        (amount: 2100, emoji: "🍱", label: "Dinner")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                // Close button
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.card)
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
                                    .fill(Color.gray.opacity(0.3))
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
                                    .fill(Color.gray.opacity(0.3))
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
                                    .foregroundColor(.blue)
                                    .font(.system(size: 18))
                                Text(nip05)
                                    .font(.system(size: 18))
                                    .foregroundColor(.blue)
                            }
                        }

                        // Bio/About
                        if let about = profile.about, !about.isEmpty {
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
                            .fill(Color.gray.opacity(0.3))
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
                    .background(Color.gray.opacity(0.3))
                    .padding(.horizontal, 30)

                // Zap Section
                VStack(alignment: .leading, spacing: 20) {
                    Text("Buy \(stream.profile?.displayNameOrName ?? "Streamer") Coffee")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)

                    if stream.profile?.lud16 == nil || stream.profile?.lud16?.isEmpty == true {
                        VStack(spacing: 15) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundColor(.orange)

                            Text("⚠️ This streamer hasn't set up Lightning zaps")
                                .font(.system(size: 20))
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 30)
                    } else if !authManager.isAuthenticated {
                        VStack(spacing: 15) {
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)

                            Text("Please sign in to send authenticated zaps")
                                .font(.system(size: 20))
                                .foregroundColor(.gray)
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
                                    .foregroundColor(.yellow)
                            }

                            if isGenerating {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Generating QR code...")
                                    .font(.system(size: 20))
                                    .foregroundColor(.gray)
                            } else if let error = errorMessage {
                                // Error state
                                VStack(spacing: 15) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 40))
                                        .foregroundColor(.red)

                                    Text(error)
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)

                                    Button("Try Again") {
                                        errorMessage = nil
                                        if let amount = selectedAmount {
                                            handleAmountSelection(amount)
                                        }
                                    }
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                                    .frame(width: 180, height: 50)
                                    .background(Color.blue)
                                    .cornerRadius(10)
                                    .buttonStyle(.card)
                                }
                            } else if let qrImage = qrCodeImage {
                                Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 400, height: 400)
                                    .background(Color.white)
                                    .cornerRadius(20)
                                    .shadow(color: .yellow.opacity(0.3), radius: 15)
                            }

                            // Instructions
                            Text("Scan to send zap")
                                .font(.system(size: 20))
                                .foregroundColor(.gray)

                            // Back button
                            if errorMessage == nil {
                                Button(action: {
                                    showQRCode = false
                                    selectedAmount = nil
                                    qrCodeImage = nil
                                    invoiceURI = nil
                                    errorMessage = nil
                                }) {
                                    Text("Back")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .frame(width: 180, height: 50)
                                        .background(Color.gray)
                                        .cornerRadius(10)
                                }
                                .buttonStyle(.card)
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
                let nostrSDKClient = try NostrSDKClient()
                let generator = ZapRequestGenerator(
                    nostrSDKClient: nostrSDKClient,
                    authManager: authManager
                )

                let uri = try await generator.generateZapRequest(
                    stream: stream,
                    amount: amount,
                    comment: "Sent from nostrTV",
                    lud16: lud16,
                    keyPair: nil
                )

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
