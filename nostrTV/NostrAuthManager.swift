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

    private var nostrSDKClient: NostrSDKClient
    private let bunkerSessionManager = BunkerSessionManager()

    init() {
        // Initialize NostrSDKClient
        do {
            self.nostrSDKClient = try NostrSDKClient()
        } catch {
            fatalError("Failed to initialize NostrSDKClient: \(error)")
        }

        // Check for bunker session and restore if exists
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
        } else if let storedNsec = KeychainHelper.load(),
                  let keyPair = try? NostrKeyPair(nsec: storedNsec) {
            // Restore nsec session
            authMethod = .nsec(keyPair: keyPair)
            currentUser = UserSession(nip05: "", hexPubkey: keyPair.publicKeyHex)
            isAuthenticated = true
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
              let relay = bunkerClient.bunkerRelays.first,
              let clientPrivateKeyHex = bunkerClient.clientPrivateKeyHex else {
            errorMessage = "Invalid bunker configuration"
            return
        }

        // Create and save session with client keypair for persistence
        let session = BunkerSession(
            bunkerPubkey: bunkerPubkey,
            relay: relay,
            userPubkey: userPubkey,
            clientPrivateKeyHex: clientPrivateKeyHex,
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

    // MARK: - nsec Authentication

    /// Authenticate directly with an nsec private key
    @MainActor
    func authenticateWithNsec(_ nsec: String) async throws {
        guard let keyPair = try? NostrKeyPair(nsec: nsec) else {
            throw NostrAuthError.invalidNsec
        }

        KeychainHelper.save(nsec)
        authMethod = .nsec(keyPair: keyPair)
        currentUser = UserSession(nip05: "", hexPubkey: keyPair.publicKeyHex)
        isAuthenticated = true
        isLoadingProfile = true
        fetchUserData(force: true)
    }

    /// Restore a bunker session on app launch (lazy — no network calls)
    /// Relay connection is deferred until the first actual signing request
    @MainActor
    private func restoreBunkerSession(_ session: BunkerSession) async {
        do {
            // Recreate bunker client
            let client = NostrBunkerClient(keyManager: NostrKeyManager.shared)

            // Restore session state without connecting to relays
            try client.restoreFromSession(
                bunkerPubkey: session.bunkerPubkey,
                relays: [session.relay],
                clientPrivateKeyHex: session.clientPrivateKeyHex
            )

            // Update session last used
            bunkerSessionManager.updateLastUsed()

            self.bunkerClient = client

            print("✅ Bunker session restored (lazy — will connect on first use)")

        } catch {
            print("⚠️ Failed to restore bunker session: \(error.localizedDescription)")
            // Don't log out automatically - user can still use cached data
        }
    }

    func logout() {
        // Disconnect bunker client
        if let client = bunkerClient {
            Task { @MainActor in
                client.disconnect()
            }
        }
        bunkerClient = nil

        // Clear bunker session
        bunkerSessionManager.clearSession()

        // Clear nsec from Keychain
        KeychainHelper.delete()

        // Clear UserDefaults
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

    /// Sign a Nostr event using the active auth method
    func signEvent(_ event: NostrEvent) async throws -> NostrEvent {
        switch authMethod {
        case .bunker:
            guard let bunkerClient = bunkerClient else {
                throw NostrAuthError.bunkerNotConnected
            }
            return try await bunkerClient.signEvent(event)
        case .nsec(let keyPair):
            return try nostrSDKClient.createSignedEvent(
                kind: event.kind,
                content: event.content ?? "",
                tags: event.tags,
                using: keyPair
            )
        case nil:
            throw NostrAuthError.notAuthenticated
        }
    }
}

// MARK: - Errors

enum NostrAuthError: LocalizedError {
    case notAuthenticated
    case bunkerNotConnected
    case invalidNsec

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User is not authenticated"
        case .bunkerNotConnected:
            return "Bunker client not connected"
        case .invalidNsec:
            return "Invalid nsec key. Please check and try again."
        }
    }
}

// MARK: - Auth Method Enum

enum AuthMethod {
    case bunker(session: BunkerSession)
    case nsec(keyPair: NostrKeyPair)
}

struct UserSession {
    let nip05: String
    let hexPubkey: String
}
