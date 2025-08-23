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
        // Add logo overlay
        let logoImageView = UIImageView(image: UIImage(named: "Logo"))
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.contentMode = .scaleAspectFit
        controller.contentOverlayView?.addSubview(logoImageView)

        NSLayoutConstraint.activate([
            logoImageView.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 10),
            logoImageView.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            logoImageView.widthAnchor.constraint(equalToConstant: 100),
            logoImageView.heightAnchor.constraint(equalToConstant: 50)
        ])

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

// Custom controller that disables the idle timer
class CustomAVPlayerViewController: AVPlayerViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
