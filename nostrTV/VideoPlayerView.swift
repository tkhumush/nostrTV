//
//  VideoPlayerView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins

struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let lightningAddress: String?

    init(player: AVPlayer, lightningAddress: String? = nil) {
        self.player = player
        self.lightningAddress = lightningAddress
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = CustomAVPlayerViewController()
        controller.player = player

        if let address = lightningAddress, let qrImage = generateQRCode(from: address) {
            let qrImageView = UIImageView(image: qrImage)
            qrImageView.translatesAutoresizingMaskIntoConstraints = false
            qrImageView.contentMode = .scaleAspectFit
            controller.contentOverlayView?.addSubview(qrImageView)

            NSLayoutConstraint.activate([
                qrImageView.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
                qrImageView.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
                qrImageView.widthAnchor.constraint(equalToConstant: 180),
                qrImageView.heightAnchor.constraint(equalToConstant: 180)
            ])

            let emojiLabel = UILabel()
            emojiLabel.text = "⚡️"
            emojiLabel.font = UIFont.systemFont(ofSize: 64, weight: .bold)
            emojiLabel.textAlignment = .center
            emojiLabel.backgroundColor = .clear
            emojiLabel.translatesAutoresizingMaskIntoConstraints = false
            qrImageView.addSubview(emojiLabel)

            NSLayoutConstraint.activate([
                emojiLabel.centerXAnchor.constraint(equalTo: qrImageView.centerXAnchor),
                emojiLabel.centerYAnchor.constraint(equalTo: qrImageView.centerYAnchor),
                emojiLabel.widthAnchor.constraint(equalToConstant: 70),
                emojiLabel.heightAnchor.constraint(equalToConstant: 70)
            ])

            // Set up auto-hide functionality
            controller.setupQRCodeAutoHide(qrImageView: qrImageView)
        }

        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        let data = Data(string.utf8)
        filter.setValue(data, forKey: "inputMessage")
        // Set error correction level to 'Q' for higher data density (can be 'L','M','Q','H')
        filter.setValue("Q", forKey: "inputCorrectionLevel")

        if let outputImage = filter.outputImage {
            // Calculate scaling factor to reach desired size while preserving sharpness
            let targetDimension: CGFloat = 600
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

// Custom controller that disables the idle timer and manages QR code auto-hide
class CustomAVPlayerViewController: AVPlayerViewController {
    private var qrCodeImageView: UIImageView?
    private var hideTimer: Timer?
    private var gestureRecognizers: [UIGestureRecognizer] = []

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        hideTimer?.invalidate()
        hideTimer = nil
    }

    func setupQRCodeAutoHide(qrImageView: UIImageView) {
        self.qrCodeImageView = qrImageView

        // Start the initial hide timer
        startHideTimer()

        // Add gesture recognizers to detect user interaction
        setupInteractionDetection()
    }

    private func setupInteractionDetection() {
        // Clear any existing gesture recognizers
        gestureRecognizers.forEach { view.removeGestureRecognizer($0) }
        gestureRecognizers.removeAll()

        // Add tap gesture recognizer
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(userInteracted))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)
        gestureRecognizers.append(tapGesture)

        // Add pan gesture recognizer for swipe detection
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(userInteracted))
        panGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(panGesture)
        gestureRecognizers.append(panGesture)
    }

    @objc private func userInteracted() {
        // Show QR code and restart timer
        showQRCode()
        startHideTimer()
    }

    private func startHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: false) { [weak self] _ in
            self?.hideQRCode()
        }
    }

    private func showQRCode() {
        guard let qrImageView = qrCodeImageView else { return }

        UIView.animate(withDuration: 0.3) {
            qrImageView.alpha = 1.0
        }
    }

    private func hideQRCode() {
        guard let qrImageView = qrCodeImageView else { return }

        UIView.animate(withDuration: 0.5) {
            qrImageView.alpha = 0.0
        }
    }

    // Override remote control methods to detect Apple TV remote interactions
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesBegan(presses, with: event)
        userInteracted()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        userInteracted()
    }
}
