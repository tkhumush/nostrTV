//
//  NostrAuthManager.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import Foundation
import Combine

class NostrAuthManager: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var currentUser: UserSession?
    @Published var currentProfile: Profile?
    @Published var followList: [String] = []
    @Published var isLoadingProfile: Bool = false
    @Published var errorMessage: String?

    private let userDefaultsKey = "nostrUserNip05"
    private let nostrClient = NostrClient()

    init() {
        // Check if user is already logged in
        if let savedNip05 = UserDefaults.standard.string(forKey: userDefaultsKey),
           let savedPubkey = UserDefaults.standard.string(forKey: "nostrUserPubkey") {
            currentUser = UserSession(nip05: savedNip05, hexPubkey: savedPubkey)
            isAuthenticated = true

            // Load cached profile data
            loadCachedProfile()

            // Ensure loading state is false when using cached data
            isLoadingProfile = false
        }
    }

    private func loadCachedProfile() {
        guard let profileData = UserDefaults.standard.data(forKey: "nostrUserProfile") else { return }

        do {
            let decoder = JSONDecoder()
            currentProfile = try decoder.decode(Profile.self, from: profileData)
        } catch {
            print("Failed to decode cached profile: \(error)")
        }

        // Load follow list
        if let followData = UserDefaults.standard.data(forKey: "nostrUserFollowList") {
            do {
                let decoder = JSONDecoder()
                followList = try decoder.decode([String].self, from: followData)
            } catch {
                print("Failed to decode cached follow list: \(error)")
            }
        }
    }

    private func saveProfileToCache(_ profile: Profile) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(profile)
            UserDefaults.standard.set(data, forKey: "nostrUserProfile")
        } catch {
            print("Failed to encode profile: \(error)")
        }
    }

    private func saveFollowListToCache(_ follows: [String]) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(follows)
            UserDefaults.standard.set(data, forKey: "nostrUserFollowList")
        } catch {
            print("Failed to encode follow list: \(error)")
        }
    }

    func verifyNip05(_ nip05: String) {
        errorMessage = nil
        isLoadingProfile = true

        // Validate NIP-05 format (name@domain.com)
        let components = nip05.split(separator: "@")
        guard components.count == 2 else {
            errorMessage = "Invalid NIP-05 format. Use: name@domain.com"
            isLoadingProfile = false
            return
        }

        let name = String(components[0])
        let domain = String(components[1])

        // Fetch the .well-known/nostr.json file
        guard let url = URL(string: "https://\(domain)/.well-known/nostr.json?name=\(name)") else {
            errorMessage = "Invalid domain"
            isLoadingProfile = false
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to verify NIP-05: \(error.localizedDescription)"
                    self.isLoadingProfile = false
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    self.errorMessage = "No data received from NIP-05 verification"
                    self.isLoadingProfile = false
                }
                return
            }

            // Parse the JSON response
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let names = json["names"] as? [String: String],
                   let pubkey = names[name] {

                    // Successfully got pubkey from NIP-05
                    DispatchQueue.main.async {
                        // Save to UserDefaults
                        UserDefaults.standard.set(nip05, forKey: self.userDefaultsKey)
                        UserDefaults.standard.set(pubkey, forKey: "nostrUserPubkey")

                        // Update state
                        self.currentUser = UserSession(nip05: nip05, hexPubkey: pubkey)

                        // Fetch profile and follow list
                        self.fetchUserData()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = "NIP-05 identifier not found"
                        self.isLoadingProfile = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to parse NIP-05 response"
                    self.isLoadingProfile = false
                }
            }
        }

        task.resume()
    }

    func fetchUserData() {
        guard let user = currentUser else { return }

        // Don't fetch if already loading
        guard !isLoadingProfile else {
            print("⚠️ Already loading profile, skipping fetch")
            return
        }

        isLoadingProfile = true
        errorMessage = nil

        // Setup callback for profile
        nostrClient.onProfileReceived = { [weak self] profile in
            DispatchQueue.main.async {
                self?.currentProfile = profile
                self?.isLoadingProfile = false
                self?.saveProfileToCache(profile)
            }
        }

        // Setup callback for follow list
        nostrClient.onFollowListReceived = { [weak self] follows in
            DispatchQueue.main.async {
                self?.followList = follows
                self?.saveFollowListToCache(follows)
            }
        }

        // Set a timeout to stop loading after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self else { return }
            if self.isLoadingProfile {
                print("⚠️ Profile fetch timed out")
                self.isLoadingProfile = false
                self.errorMessage = "Failed to load profile. Using cached data if available."
            }
        }

        // Connect and fetch
        nostrClient.connectAndFetchUserData(pubkey: user.hexPubkey)
    }

    func login() {
        isAuthenticated = true
    }

    func logout() {
        // Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: "nostrUserPubkey")
        UserDefaults.standard.removeObject(forKey: "nostrUserProfile")
        UserDefaults.standard.removeObject(forKey: "nostrUserFollowList")

        // Clear state
        currentUser = nil
        currentProfile = nil
        followList = []
        isAuthenticated = false
        errorMessage = nil

        // Disconnect client
        nostrClient.disconnect()
    }
}

struct UserSession {
    let nip05: String
    let hexPubkey: String
}
