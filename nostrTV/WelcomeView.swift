//
//  WelcomeView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI

struct WelcomeView: View {
    @ObservedObject var authManager: NostrAuthManager
    @State private var nip05Input: String = ""
    @State private var showBunkerLogin: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            // Logo or Title
            Text("nostrTV")
                .font(.system(size: 72, weight: .bold))
                .foregroundColor(.white)

            // Instruction text
            Text("Enter your NIP-05 identifier")
                .font(.system(size: 28))
                .foregroundColor(.gray)

            // Example text
            Text("Example: user@domain.com")
                .font(.system(size: 20))
                .foregroundColor(.gray.opacity(0.7))

            // Text input field
            TextField("user@domain.com", text: $nip05Input)
                .focused($isTextFieldFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 24))
                .padding()
                .frame(width: 800)
                .background(Color.white.opacity(0.1))
                .cornerRadius(10)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.emailAddress)
                .onSubmit {
                    submitNip05()
                }

            // Error message
            if let error = authManager.errorMessage {
                Text(error)
                    .font(.system(size: 20))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Submit button
            Button(action: submitNip05) {
                if authManager.isLoadingProfile {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 300, height: 70)
                } else {
                    Text("Continue")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 300, height: 70)
                        .background(nip05Input.isEmpty ? Color.gray : Color.blue)
                        .cornerRadius(10)
                }
            }
            .disabled(nip05Input.isEmpty || authManager.isLoadingProfile)

            // Divider with "OR"
            HStack(spacing: 16) {
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(height: 1)
                Text("OR")
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(height: 1)
            }
            .frame(width: 600)
            .padding(.vertical, 20)

            // Bunker login button
            Button(action: { showBunkerLogin = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 24))
                    Text("Sign in with nsec bunker")
                        .font(.system(size: 28, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(width: 500, height: 70)
                .background(Color.purple)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .fullScreenCover(isPresented: $showBunkerLogin) {
            BunkerLoginView(authManager: authManager)
        }
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func submitNip05() {
        let trimmed = nip05Input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        authManager.verifyNip05(trimmed)
    }
}
