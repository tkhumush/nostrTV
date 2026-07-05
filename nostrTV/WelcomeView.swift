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
    @State private var showNsecLogin: Bool = false

    var body: some View {
        VStack(spacing: 40) {
            // Logo
            Text("Cove")
                .font(.coveTitle)
                .foregroundColor(.coveAccent)

            // Instruction text
            Text("Sign in to join the conversation")
                .font(.system(size: 32, weight: .regular, design: .rounded))
                .foregroundColor(.coveSecondary)

            // Error message
            if let error = authManager.errorMessage {
                Text(error)
                    .font(.coveCaption)
                    .foregroundColor(.coveGold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(spacing: 20) {
                // Primary: Bunker login
                Button(action: { showBunkerLogin = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 24))
                        Text("Sign in with nsec bunker")
                            .font(.coveSubheading)
                    }
                    .foregroundColor(.white)
                    .frame(width: 500, height: 70)
                    .background(Color.coveAccent)
                    .cornerRadius(CoveUI.smallCornerRadius)
                }
                .buttonStyle(.plain)

                // Secondary: nsec key login
                Button(action: { showNsecLogin = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 24))
                        Text("Sign in with nsec key")
                            .font(.coveSubheading)
                    }
                    .foregroundColor(.coveSecondary)
                    .frame(width: 500, height: 70)
                    .background(Color.coveOverlay)
                    .cornerRadius(CoveUI.smallCornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: CoveUI.smallCornerRadius)
                            .stroke(Color.coveSecondary.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.coveBackground)
        .fullScreenCover(isPresented: $showBunkerLogin) {
            BunkerLoginView(authManager: authManager)
        }
        .fullScreenCover(isPresented: $showNsecLogin) {
            NsecLoginView(authManager: authManager)
        }
    }
}
