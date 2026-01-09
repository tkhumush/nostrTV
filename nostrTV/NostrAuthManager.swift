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
    @Published var authMethod: AuthMethod? = nil
    @Published var bunkerClient: NostrBunkerClient?

    private let userDefaultsKey = "nostrUserNip05"
    private var nostrSDKClient: NostrSDKClient
    private let bunkerSessionManager = BunkerSessionManager()

    init() {
        // Initialize NostrSDKClient
        do {
            self.nostrSDKClient = try NostrSDKClient()
        } catch {
            fatalError("Failed to initialize NostrSDKClient: \(error)")
        }

        // Check for bunker session first
        if let bunkerSession = bunkerSessionManager.loadSession(),
           let userPubkey = bunkerSession.userPubkey {
            // Restore bunker session
            authMethod = .bunker(session: bunkerSession)
            currentUser = UserSession(nip05: "bunker:\(bunkerSession.bunkerPubkey.prefix(8))...", hexPubkey: userPubkey)
            isAuthenticated = true

            // Load cached profile data
            loadCachedProfile()
            isLoadingProfile = false

            // Reconnect bunker client in background
            Task { @MainActor in
                await restoreBunkerSession(bunkerSession)
            }
        }
        // Fall back to NIP-05 login
        else if let savedNip05 = UserDefaults.standard.string(forKey: userDefaultsKey),
                let savedPubkey = UserDefaults.standard.string(forKey: "nostrUserPubkey") {
            authMethod = .nip05(nip05: savedNip05, pubkey: savedPubkey)
            currentUser = UserSession(nip05: savedNip05, hexPubkey: savedPubkey)
            isAuthenticated = true

            // Load cached profile data
            loadCachedProfile()
            isLoadingProfile = false
        }
    }

    private func loadCachedProfile() {
        guard let profileData = UserDefaults.standard.data(forKey: "nostrUserProfile") else { return }

        do {
            let decoder = JSONDecoder()
            currentProfile = try decoder.decode(Profile.self, from: profileData)
        } catch {
            // Failed to decode cached profile
        }

        // Load follow list
        if let followData = UserDefaults.standard.data(forKey: "nostrUserFollowList") {
            do {
                let decoder = JSONDecoder()
                followList = try decoder.decode([String].self, from: followData)
            } catch {
                // Failed to decode cached follow list
            }
        }
    }

    private func saveProfileToCache(_ profile: Profile) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(profile)
            UserDefaults.standard.set(data, forKey: "nostrUserProfile")
        } catch {
            // Failed to encode profile
        }
    }

    private func saveFollowListToCache(_ follows: [String]) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(follows)
            UserDefaults.standard.set(data, forKey: "nostrUserFollowList")
        } catch {
            // Failed to encode follow list
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

                        // Keep isLoadingProfile true and fetch profile data
                        // Don't set isLoadingProfile to false here - let fetchUserData manage it
                        self.fetchUserData(force: true)
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

    func fetchUserData(force: Bool = false) {
        guard let user = currentUser else { return }

        // Don't fetch if already loading (unless forced during initial login)
        guard force || !isLoadingProfile else {
            return
        }

        isLoadingProfile = true
        errorMessage = nil

        // Setup callback for profile
        nostrSDKClient.addProfileReceivedCallback { [weak self] profile in
            DispatchQueue.main.async {
                self?.currentProfile = profile
                self?.isLoadingProfile = false
                self?.saveProfileToCache(profile)
            }
        }

        // Setup callback for follow list
        nostrSDKClient.onFollowListReceived = { [weak self] follows in
            DispatchQueue.main.async {
                self?.followList = follows
                self?.saveFollowListToCache(follows)
            }
        }

        // Set a timeout to stop loading after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self else { return }
            if self.isLoadingProfile {
                self.isLoadingProfile = false
                self.errorMessage = "Failed to load profile. Using cached data if available."
            }
        }

        // Connect and fetch
        nostrSDKClient.connectAndFetchUserData(pubkey: user.hexPubkey)
    }

    func login() {
        isAuthenticated = true
    }

    // MARK: - Bunker Authentication

    /// Authenticate with a remote bunker
    @MainActor
    func authenticateWithBunker(bunkerClient: NostrBunkerClient, userPubkey: String) async {
        self.bunkerClient = bunkerClient

        guard let bunkerPubkey = bunkerClient.bunkerPubkey,
              let relay = bunkerClient.bunkerRelay else {
            errorMessage = "Invalid bunker configuration"
            return
        }

        // Create and save session
        let session = BunkerSession(
            bunkerPubkey: bunkerPubkey,
            relay: relay,
            userPubkey: userPubkey,
            createdAt: Date(),
            lastUsed: Date()
        )

        bunkerSessionManager.saveSession(session)
        authMethod = .bunker(session: session)

        // Update user session
        currentUser = UserSession(nip05: "bunker:\(bunkerPubkey.prefix(8))...", hexPubkey: userPubkey)

        // Fetch profile data
        isLoadingProfile = true
        fetchUserData(force: true)

        // Mark as authenticated
        isAuthenticated = true
    }

    /// Restore a bunker session on app launch
    @MainActor
    private func restoreBunkerSession(_ session: BunkerSession) async {
        do {
            // Recreate bunker client
            let client = NostrBunkerClient(keyManager: NostrKeyManager.shared)

            // Attempt to reconnect
            let uri = BunkerURIComponents(
                clientPubkey: session.bunkerPubkey,
                relay: session.relay,
                secret: nil,
                metadata: nil
            ).toURI()

            try await client.connect(bunkerURI: uri)

            // Update session last used
            bunkerSessionManager.updateLastUsed()

            self.bunkerClient = client

            print("✅ Bunker session restored successfully")

        } catch {
            print("⚠️ Failed to restore bunker session: \(error.localizedDescription)")
            // Don't log out automatically - user can still use cached data
        }
    }

    func logout() {
        // Handle auth-method-specific cleanup
        switch authMethod {
        case .nip05:
            // Clear NIP-05 UserDefaults
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            UserDefaults.standard.removeObject(forKey: "nostrUserPubkey")

        case .bunker:
            // Disconnect bunker client
            if let client = bunkerClient {
                Task { @MainActor in
                    client.disconnect()
                }
            }
            bunkerClient = nil

            // Clear bunker session
            bunkerSessionManager.clearSession()

        case .none:
            break
        }

        // Clear common UserDefaults
        UserDefaults.standard.removeObject(forKey: "nostrUserProfile")
        UserDefaults.standard.removeObject(forKey: "nostrUserFollowList")

        // Clear state
        currentUser = nil
        currentProfile = nil
        followList = []
        isAuthenticated = false
        authMethod = nil
        errorMessage = nil

        // Disconnect client
        nostrSDKClient.disconnect()
    }

    // MARK: - Event Signing

    /// Sign a Nostr event using the current authentication method (bunker or local keys)
    func signEvent(_ event: NostrEvent) async throws -> NostrEvent {
        switch authMethod {
        case .bunker:
            // Use bunker for remote signing
            guard let bunkerClient = bunkerClient else {
                throw NostrAuthError.bunkerNotConnected
            }
            return try await bunkerClient.signEvent(event)

        case .nip05:
            // Use local keypair signing
            guard let keyPair = NostrKeyManager.shared.currentKeyPair else {
                throw NostrAuthError.noKeyPairAvailable
            }
            // Sign locally using NostrSDKClient
            return try nostrSDKClient.createSignedEvent(
                kind: event.kind,
                content: event.content ?? "",
                tags: event.tags,
                using: keyPair
            )

        case .none:
            throw NostrAuthError.notAuthenticated
        }
    }
}

// MARK: - Errors

enum NostrAuthError: LocalizedError {
    case notAuthenticated
    case noKeyPairAvailable
    case bunkerNotConnected

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User is not authenticated"
        case .noKeyPairAvailable:
            return "No key pair available for signing"
        case .bunkerNotConnected:
            return "Bunker client not connected"
        }
    }
}

// MARK: - Auth Method Enum

enum AuthMethod {
    case nip05(nip05: String, pubkey: String)
    case bunker(session: BunkerSession)
}

struct UserSession {
    let nip05: String
    let hexPubkey: String
}
