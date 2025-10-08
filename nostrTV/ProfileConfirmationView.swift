//
//  ProfileConfirmationView.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI

struct ProfileConfirmationView: View {
    @ObservedObject var authManager: NostrAuthManager

    var body: some View {
        VStack(spacing: 50) {
            // Title
            Text("nostrTV")
                .font(.system(size: 72, weight: .bold))
                .foregroundColor(.white)

            if authManager.isLoadingProfile {
                // Loading state
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.white)
                    Text("Loading your profile...")
                        .font(.system(size: 28))
                        .foregroundColor(.gray)
                }
            } else if let profile = authManager.currentProfile {
                // Profile loaded
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

                    // Buttons
                    HStack(spacing: 30) {
                        // Logout button
                        Button(action: {
                            authManager.logout()
                        }) {
                            Text("Log Out")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 250, height: 70)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(10)
                        }

                        // Login button
                        Button(action: {
                            authManager.login()
                        }) {
                            Text("Log In")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 250, height: 70)
                                .background(Color.blue)
                                .cornerRadius(10)
                        }
                    }
                    .padding(.top, 20)
                }
            } else {
                // Error state - no profile found
                VStack(spacing: 30) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.orange)

                    Text("Could not load profile")
                        .font(.system(size: 28))
                        .foregroundColor(.white)

                    Text("Please check your NIP-05 and try again")
                        .font(.system(size: 22))
                        .foregroundColor(.gray)

                    Button(action: {
                        authManager.logout()
                    }) {
                        Text("Try Again")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 300, height: 70)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
