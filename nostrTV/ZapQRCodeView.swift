//
//  ZapQRCodeView.swift
//  nostrTV
//
//  Created by Claude Code
//

import SwiftUI
import CoreImage.CIFilterBuiltins

/// Displays a QR code for a lightning invoice
struct ZapQRCodeView: View {
    let invoiceURI: String
    let zapOption: ZapOption
    let onDismiss: () -> Void

    @State private var qrImage: UIImage? = nil
    @State private var isGenerating = true

    var body: some View {
        ZStack {
            // Semi-transparent background - don't dismiss on tap, use Done button
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                // Header - reduced spacing and font sizes
                VStack(spacing: 10) {
                    Text(zapOption.emoji)
                        .font(.system(size: 70))

                    Text("Scan to Zap")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: 8) {
                        Text("\(zapOption.displayAmount) sats")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.yellow)

                        Text("•")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.gray)

                        Text(zapOption.message)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }

                // QR Code - reduced size
                if let qrImage = qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 450, height: 450)
                        .background(Color.white)
                        .cornerRadius(20)
                        .shadow(color: .yellow.opacity(0.3), radius: 20)
                } else if isGenerating {
                    // Loading indicator while generating
                    ZStack {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 450, height: 450)
                            .cornerRadius(20)
                        ProgressView()
                            .scaleEffect(2.0)
                            .tint(.gray)
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 450, height: 450)
                        .cornerRadius(20)
                        .overlay(
                            Text("Failed to generate QR code")
                                .foregroundColor(.white)
                        )
                }

                // Instructions - reduced spacing
                VStack(spacing: 8) {
                    Text("Scan with your Lightning wallet")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }

                // Done button - native Liquid Glass style
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .font(.system(size: 30, weight: .semibold))
                    .controlSize(.large)
            }
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 50)
        }
        .onAppear {
            // Generate QR code on background thread to avoid blocking UI
            Task.detached(priority: .userInitiated) {
                let image = await generateQRCodeAsync(from: invoiceURI)
                await MainActor.run {
                    qrImage = image
                    isGenerating = false
                }
            }
        }
    }

    private func generateQRCodeAsync(from string: String) async -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        let data = Data(string.utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("Q", forKey: "inputCorrectionLevel")

        if let outputImage = filter.outputImage {
            let targetDimension: CGFloat = 1000
            let scaleX = targetDimension / outputImage.extent.size.width
            let scaleY = targetDimension / outputImage.extent.size.height
            let transformedImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            if let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) {
                return UIImage(cgImage: cgImage)
            }
        }
        return nil
    }
}

#Preview {
    ZapQRCodeView(
        invoiceURI: "lightning:lnbc1000n1pj9x7xzpp5test...",
        zapOption: ZapOption.presets[2],
        onDismiss: {
            print("Dismissed")
        }
    )
}
