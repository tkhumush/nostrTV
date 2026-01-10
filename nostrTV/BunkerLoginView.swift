import SwiftUI
import CoreImage.CIFilterBuiltins

/// View for bunker-based login with QR code
struct BunkerLoginView: View {

    // MARK: - Properties

    @ObservedObject var authManager: NostrAuthManager
    @StateObject private var bunkerClient: NostrBunkerClient
    @Environment(\.dismiss) private var dismiss

    @State private var qrCodeImage: UIImage?
    @State private var bunkerURI: String = ""
    @State private var isGenerating: Bool = true
    @State private var errorMessage: String?

    // MARK: - Initialization

    init(authManager: NostrAuthManager) {
        self.authManager = authManager
        _bunkerClient = StateObject(wrappedValue: NostrBunkerClient(
            keyManager: NostrKeyManager.shared
        ))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()

            HStack(spacing: 80) {
                // Left Column: Text and Buttons
                VStack(spacing: 40) {
                    Spacer()

                    // Title
                    Text("nostrTV")
                        .font(.system(size: 72, weight: .bold))
                        .foregroundColor(.white)

                    Text("Sign in with nsec bunker")
                        .font(.system(size: 32))
                        .foregroundColor(.gray)

                    // Status Section
                    statusSection
                        .frame(height: 200)

                    // Cancel Button
                    Button(action: {
                        bunkerClient.disconnect()
                        dismiss()
                    }) {
                        Text("Cancel")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .frame(width: 300, height: 70)
                            .background(Color.gray)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // Right Column: QR Code
                VStack {
                    Spacer()
                    qrCodeSection
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(60)
        }
        .onAppear {
            startBunkerFlow()
        }
        .onChange(of: bunkerClient.connectionState) { _, newState in
            handleConnectionStateChange(newState)
        }
    }

    // MARK: - QR Code Section

    @ViewBuilder
    private var qrCodeSection: some View {
        if let qrImage = qrCodeImage {
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 500, height: 500)
                .background(Color.white)
                .cornerRadius(20)
                .shadow(color: .purple.opacity(0.3), radius: 20)
        } else if isGenerating {
            ZStack {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 500, height: 500)
                    .cornerRadius(20)

                ProgressView()
                    .scaleEffect(2.0)
                    .tint(.gray)
            }
        } else if let error = errorMessage {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 500, height: 500)
                .cornerRadius(20)
                .overlay(
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.red)
                        Text("Failed to generate QR code")
                            .foregroundColor(.white)
                            .font(.system(size: 20))
                        Text(error)
                            .foregroundColor(.gray)
                            .font(.system(size: 16))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                )
        }
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        switch bunkerClient.connectionState {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("Connecting to bunker relay...")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
            }

        case .waitingForScan:
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.purple)
                Text("Scan the QR code")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                Text("Use Amber, Amethyst, or compatible app")
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
            }

        case .waitingForApproval:
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.purple)
                Text("Approve the connection on your phone")
                    .font(.system(size: 24))
                    .foregroundColor(.purple)
            }

        case .connected(let userPubkey):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                Text("Connected!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.green)
                Text("Fetching your profile...")
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
            }

        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                Text("Connection Failed")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.red)
                Text(message)
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button(action: {
                    startBunkerFlow()
                }) {
                    Text("Try Again")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 200, height: 50)
                        .background(Color.purple)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }

        case .disconnected:
            EmptyView()
        }
    }

    // MARK: - Bunker Flow

    private func startBunkerFlow() {
        Task {
            do {
                isGenerating = true
                errorMessage = nil

                // Generate bunker URI
                bunkerURI = try await generateBunkerURI()

                // Generate QR code
                qrCodeImage = await generateQRCode(from: bunkerURI)

                isGenerating = false

                // Start listening for bunker connection (reverse flow)
                // The signer will initiate by sending connect response after scanning QR
                try await bunkerClient.waitForSignerConnection(bunkerURI: bunkerURI)

                // Once signer connects and secret is validated, get public key
                let userPubkey = try await bunkerClient.getPublicKey()

                // Authenticate with auth manager
                await authManager.authenticateWithBunker(
                    bunkerClient: bunkerClient,
                    userPubkey: userPubkey
                )

                // Close this view
                dismiss()

            } catch {
                isGenerating = false
                errorMessage = error.localizedDescription
                bunkerClient.connectionState = .error(error.localizedDescription)
            }
        }
    }

    /// Generate nostrconnect:// URI for QR code (reverse flow)
    private func generateBunkerURI() async throws -> String {
        // Ensure key manager has a keypair for bunker handshake
        if !NostrKeyManager.shared.hasKeyPair {
            try NostrKeyManager.shared.generateEphemeralKeyPair()
        }

        guard let clientPubkey = NostrKeyManager.shared.publicKeyHex else {
            throw BunkerError.connectionFailed("Failed to generate client keys")
        }

        // Use a well-known relay for bunker communication
        let relay = "wss://relay.primal.net"

        // Generate random secret for validation
        let secret = UUID().uuidString

        // Optional metadata about the app
        let metadata: [String: String] = [
            "name": "nostrTV",
            "url": "https://nostrtv.app"
        ]

        let components = BunkerURIComponents(
            clientPubkey: clientPubkey,
            relay: relay,
            secret: secret,
            metadata: metadata
        )

        return components.toNostrConnectURI()
    }

    /// Generate QR code image from bunker URI
    private func generateQRCode(from string: String) async -> UIImage? {
        return await Task.detached(priority: .userInitiated) {
            let context = CIContext()
            let filter = CIFilter.qrCodeGenerator()
            let data = Data(string.utf8)

            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("Q", forKey: "inputCorrectionLevel")

            if let outputImage = filter.outputImage {
                // Scale up for better quality (1000x1000 pixels)
                let targetDimension: CGFloat = 1000
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

    // MARK: - Connection State Handling

    private func handleConnectionStateChange(_ state: BunkerConnectionState) {
        switch state {
        case .connected(let userPubkey):
            // This is handled in startBunkerFlow
            break

        case .error(let message):
            errorMessage = message

        default:
            break
        }
    }
}
