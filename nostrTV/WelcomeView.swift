//
//  WelcomeView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI

struct WelcomeView: View {
    @ObservedObject var authManager: NostrAuthManager
    @State private var showBunkerLogin: Bool = false

    var body: some View {
        VStack(spacing: 40) {
            // Logo or Title
            Text("nostrTV")
                .font(.system(size: 72, weight: .bold))
                .foregroundColor(.white)

            // Instruction text
            Text("Sign in to send zaps and chat")
                .font(.system(size: 32))
                .foregroundColor(.gray)

            Text("Use your nsec bunker to sign in")
                .font(.system(size: 24))
                .foregroundColor(.gray.opacity(0.7))

            // Error message
            if let error = authManager.errorMessage {
                Text(error)
                    .font(.system(size: 20))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

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
    }
}
