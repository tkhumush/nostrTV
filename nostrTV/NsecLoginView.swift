import SwiftUI

struct NsecLoginView: View {
    @ObservedObject var authManager: NostrAuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var nsecInput: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.coveBackground
                .ignoresSafeArea()

            HStack(spacing: 80) {
                // Left column: input form
                VStack(spacing: 40) {
                    Spacer()

                    Text("Cove")
                        .font(.coveTitle)
                        .foregroundColor(.coveAccent)

                    Text("Sign in with nsec")
                        .font(.system(size: 32, weight: .regular, design: .rounded))
                        .foregroundColor(.coveSecondary)

                    VStack(spacing: 16) {
                        SecureField("nsec1...", text: $nsecInput)
                            .font(.system(size: 24, design: .monospaced))
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.coveOverlay)
                            .cornerRadius(CoveUI.badgeCornerRadius)
                            .frame(width: 520)
                            .disabled(isLoading)

                        if let error = errorMessage {
                            Text(error)
                                .font(.coveCaption)
                                .foregroundColor(.coveGold)
                                .multilineTextAlignment(.center)
                                .frame(width: 520)
                        }
                    }
                    .frame(height: 120)

                    if isLoading {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.coveAccent)
                    } else {
                        Button(action: signIn) {
                            Text("Sign In")
                                .font(.coveSubheading)
                                .foregroundColor(.white)
                                .frame(width: 300, height: 70)
                                .background(nsecInput.isEmpty ? Color.coveAccent.opacity(0.4) : Color.coveAccent)
                                .cornerRadius(CoveUI.smallCornerRadius)
                        }
                        .buttonStyle(.plain)
                        .disabled(nsecInput.isEmpty)
                    }

                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(.coveSecondary)
                    .font(.coveSubheading)
                    .controlSize(.large)

                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // Right column: explanation
                VStack(spacing: 30) {
                    Spacer()

                    Image(systemName: "lock.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.coveAccent)

                    Text("Your private key")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Enter your Nostr private key (nsec) to sign in directly. Your key is stored securely on this device and never sent to any server.")
                        .font(.coveBody)
                        .foregroundColor(.coveSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)

                    Text("Keep your nsec secret — it controls your Nostr identity.")
                        .font(.coveCaption)
                        .foregroundColor(.coveGold)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(60)
        }
    }

    private func signIn() {
        let trimmed = nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                try await authManager.authenticateWithNsec(trimmed)
                dismiss()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
