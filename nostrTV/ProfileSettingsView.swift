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
        VStack(spacing: 0) {
            // Title
            Text("Profile")
                .font(.system(size: 56, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 40)
                .padding(.bottom, 40)

            if let profile = authManager.currentProfile {
                VStack(alignment: .center, spacing: 40) {
                    // Three-column layout: Profile picture | Profile info | Bunker card
                    HStack(alignment: .top, spacing: 60) {
                        // Column 1: Profile picture
                        AsyncImage(url: URL(string: profile.picture ?? "")) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 120))
                                        .foregroundColor(.white)
                                )
                        }
                        .frame(width: 300, height: 300)
                        .clipShape(Circle())

                        // Column 2: Profile info
                        VStack(alignment: .leading, spacing: 16) {
                            Text(profile.displayName ?? profile.name ?? "Nostr User")
                                .font(.system(size: 50, weight: .semibold))
                                .foregroundColor(.white)

                            if let name = profile.name {
                                Text("@\(name)")
                                    .font(.system(size: 31))
                                    .foregroundColor(.secondary)
                            }

                            if let nip05 = profile.nip05, !nip05.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 25))
                                        .foregroundColor(.blue)
                                    Text(nip05)
                                        .font(.system(size: 28))
                                        .foregroundColor(.blue)
                                }
                            }

                            if let about = profile.about, !about.isEmpty {
                                Text(about)
                                    .font(.system(size: 25))
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                                    .padding(.top, 8)
                            }

                            if let lud16 = profile.lud16, !lud16.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 25))
                                        .foregroundColor(.yellow)
                                    Text(lud16)
                                        .font(.system(size: 25))
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Following count
                            if !authManager.followList.isEmpty {
                                HStack(spacing: 12) {
                                    Text("Following:")
                                        .foregroundColor(.secondary)
                                    Text("\(authManager.followList.count)")
                                        .fontWeight(.semibold)
                                }
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .padding(.top, 8)
                            }
                        }

                        // Column 3: Bunker Connection Card
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 34))
                                    .foregroundColor(.purple)
                                Text("Bunker Connection")
                                    .font(.system(size: 34, weight: .semibold))
                                    .foregroundColor(.white)
                            }

                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 14, height: 14)
                                Text("Connected")
                                    .font(.system(size: 25))
                                    .foregroundColor(.green)
                                    .fontWeight(.semibold)
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.purple)
                                Text("Remote Signing Active")
                                    .font(.system(size: 25))
                                    .foregroundColor(.secondary)
                            }

                            if let pubkey = authManager.currentUser?.hexPubkey {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Public Key:")
                                        .font(.system(size: 22))
                                        .foregroundColor(.secondary)
                                    Text(pubkey.prefix(16) + "..." + pubkey.suffix(16))
                                        .font(.system(size: 20, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .padding(.top, 8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(34)
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                    }

                    Spacer()

                    // Logout button
                    VStack {
                        Button("Log Out", action: {
                            authManager.logout()
                            isPresented = false
                        })
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .font(.system(size: 39, weight: .semibold))
                        .controlSize(.large)
                    }
                    .focusSection()
                    .padding(.bottom, 60)
                }
                .frame(maxWidth: .infinity)
            } else {
                // Loading or error state
                VStack(spacing: 28) {
                    if authManager.isLoadingProfile {
                        ProgressView()
                            .scaleEffect(3)
                            .tint(.white)
                        Text("Loading profile...")
                            .font(.system(size: 39))
                            .foregroundColor(.gray)
                    } else {
                        // Not loading but no profile - show error
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 112))
                            .foregroundColor(.orange)

                        Text(authManager.errorMessage ?? "Profile not available")
                            .font(.system(size: 39))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)

                        Button("Retry", action: {
                            authManager.fetchUserData()
                        })
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .font(.system(size: 39, weight: .semibold))
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
