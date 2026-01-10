//
//  ProfileSettingsView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI

struct ProfileSettingsView: View {
    @ObservedObject var authManager: NostrAuthManager
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 50) {
            // Close button - native Liquid Glass style
            HStack {
                Spacer()
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 40))
                }
                .buttonStyle(.plain)
                .padding()
            }
            .focusSection()  // Create a focus section for the close button

            // Title
            Text("Profile")
                .font(.system(size: 60, weight: .bold))
                .foregroundColor(.white)

            if let profile = authManager.currentProfile {
                // Profile content
                VStack(spacing: 30) {
                    // Profile picture
                    AsyncImage(url: URL(string: profile.picture ?? "")) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 80))
                                    .foregroundColor(.white)
                            )
                    }
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())

                    // Username
                    Text(profile.displayName ?? profile.name ?? "Nostr User")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.white)

                    // NIP-05 identifier
                    if let nip05 = authManager.currentUser?.nip05 {
                        Text(nip05)
                            .font(.system(size: 22))
                            .foregroundColor(.blue)
                    }

                    // Follow count
                    if !authManager.followList.isEmpty {
                        Text("Following \(authManager.followList.count) users")
                            .font(.system(size: 24))
                            .foregroundColor(.gray)
                    }

                    // Logout button - native Liquid Glass style
                    VStack {
                        Button("Log Out", action: {
                            authManager.logout()
                            isPresented = false
                        })
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .font(.system(size: 28, weight: .semibold))
                        .controlSize(.large)
                    }
                    .focusSection()  // Create a focus section for the logout button
                    .padding(.top, 20)
                }
            } else {
                // Loading or error state
                VStack(spacing: 20) {
                    if authManager.isLoadingProfile {
                        ProgressView()
                            .scaleEffect(2)
                            .tint(.white)
                        Text("Loading profile...")
                            .font(.system(size: 28))
                            .foregroundColor(.gray)
                    } else {
                        // Not loading but no profile - show error
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 80))
                            .foregroundColor(.orange)

                        Text(authManager.errorMessage ?? "Profile not available")
                            .font(.system(size: 28))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)

                        Button("Retry", action: {
                            authManager.fetchUserData()
                        })
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .font(.system(size: 28, weight: .semibold))
                        .controlSize(.large)
                        .padding(.top, 20)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear {
            // If profile is not loaded but user is authenticated, fetch it
            if authManager.currentProfile == nil && authManager.isAuthenticated {
                authManager.fetchUserData()
            }
        }
    }
}
