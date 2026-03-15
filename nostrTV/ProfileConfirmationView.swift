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
            Text("Cove")
                .font(.coveTitle)
                .foregroundColor(.coveAccent)

            if authManager.isLoadingProfile {
                // Loading state
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.coveAccent)
                    Text(CoveCopy.profileLoading)
                        .font(.coveSubheading)
                        .foregroundColor(.coveSecondary)
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
                            .fill(Color.coveOverlay)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 80))
                                    .foregroundColor(.coveAccent)
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
                            .foregroundColor(.coveAccent)
                    }

                    // Follow count
                    if !authManager.followList.isEmpty {
                        Text("Following \(authManager.followList.count) users")
                            .font(.coveBody)
                            .foregroundColor(.coveSecondary)
                    }

                    // Buttons
                    HStack(spacing: 30) {
                        // Logout button
                        Button(action: {
                            authManager.logout()
                        }) {
                            Text("Log Out")
                                .font(.coveSubheading)
                                .foregroundColor(.white)
                                .frame(width: 250, height: 70)
                                .background(Color.coveSecondary.opacity(0.5))
                                .cornerRadius(CoveUI.smallCornerRadius)
                        }

                        // Login button
                        Button(action: {
                            authManager.login()
                        }) {
                            Text("Log In")
                                .font(.coveSubheading)
                                .foregroundColor(.white)
                                .frame(width: 250, height: 70)
                                .background(Color.coveAccent)
                                .cornerRadius(CoveUI.smallCornerRadius)
                        }
                    }
                    .padding(.top, 20)
                }
            } else {
                // Error state - no profile found
                VStack(spacing: 30) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.coveGold)

                    Text("Could not load profile")
                        .font(.coveSubheading)
                        .foregroundColor(.white)

                    Text("Please check your NIP-05 and try again")
                        .font(.coveBody)
                        .foregroundColor(.coveSecondary)

                    Button(action: {
                        authManager.logout()
                    }) {
                        Text("Try Again")
                            .font(.coveSubheading)
                            .foregroundColor(.white)
                            .frame(width: 300, height: 70)
                            .background(Color.coveAccent)
                            .cornerRadius(CoveUI.smallCornerRadius)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.coveBackground)
    }
}
