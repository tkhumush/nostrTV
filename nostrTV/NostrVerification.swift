//
//  NostrVerification.swift
//  nostrTV
//
//  Created by Claude Code on 1/21/26.
//  Implements NIP-05 and Lightning address verification
//

import Foundation

// MARK: - NIP-05 Verification

/// Verification status for NIP-05 addresses
enum NIP05Status {
    case unverified
    case verifying
    case verified
    case failed(String)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// NIP-05 verification service
/// Verifies nostr addresses like user@domain.com
actor NIP05Verifier {

    /// Shared instance for app-wide verification
    static let shared = NIP05Verifier()

    /// Cache of verified NIP-05 addresses
    private var verificationCache: [String: NIP05CacheEntry] = [:]

    /// Cache TTL (1 hour)
    private let cacheTTL: TimeInterval = 60 * 60

    /// Maximum cache size
    private let maxCacheSize = 200

    /// Verify a NIP-05 address matches a pubkey
    /// - Parameters:
    ///   - nip05: The NIP-05 address (e.g., "user@domain.com")
    ///   - pubkey: The expected pubkey (hex)
    /// - Returns: True if verified, false otherwise
    func verify(nip05: String, pubkey: String) async -> Bool {
        // Normalize inputs
        let normalizedNip05 = nip05.lowercased().trimmingCharacters(in: .whitespaces)
        let normalizedPubkey = pubkey.lowercased()

        // Check cache first
        let cacheKey = "\(normalizedNip05):\(normalizedPubkey)"
        if let cached = verificationCache[cacheKey] {
            if Date().timeIntervalSince(cached.timestamp) < cacheTTL {
                return cached.isVerified
            }
            // Expired, remove from cache
            verificationCache.removeValue(forKey: cacheKey)
        }

        // Parse NIP-05 address
        guard let (user, domain) = parseNIP05(normalizedNip05) else {
            cacheResult(cacheKey, isVerified: false)
            return false
        }

        // Fetch .well-known/nostr.json
        let verified = await fetchAndVerify(user: user, domain: domain, expectedPubkey: normalizedPubkey)

        // Cache result
        cacheResult(cacheKey, isVerified: verified)

        return verified
    }

    /// Parse NIP-05 address into user and domain
    private func parseNIP05(_ nip05: String) -> (user: String, domain: String)? {
        let parts = nip05.split(separator: "@")

        // Handle _@domain.com format (root user)
        if parts.count == 1 {
            // Could be _@domain or just domain
            return ("_", String(parts[0]))
        }

        guard parts.count == 2 else { return nil }

        let user = String(parts[0])
        let domain = String(parts[1])

        // Basic domain validation
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return nil
        }

        return (user, domain)
    }

    /// Fetch nostr.json and verify pubkey
    private func fetchAndVerify(user: String, domain: String, expectedPubkey: String) async -> Bool {
        // Construct URL
        let urlString = "https://\(domain)/.well-known/nostr.json?name=\(user)"
        guard let url = URL(string: urlString) else {
            print("⚠️ NIP-05: Invalid URL: \(urlString)")
            return false
        }

        do {
            // Fetch with timeout
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(from: url)

            // Verify HTTP success
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("⚠️ NIP-05: HTTP error for \(user)@\(domain)")
                return false
            }

            // Parse JSON
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let names = json["names"] as? [String: String] else {
                print("⚠️ NIP-05: Invalid JSON format for \(user)@\(domain)")
                return false
            }

            // Check if user maps to expected pubkey
            guard let foundPubkey = names[user]?.lowercased() else {
                print("⚠️ NIP-05: User '\(user)' not found in nostr.json")
                return false
            }

            let verified = foundPubkey == expectedPubkey
            if verified {
                print("✅ NIP-05: Verified \(user)@\(domain)")
            } else {
                print("⚠️ NIP-05: Pubkey mismatch for \(user)@\(domain)")
            }

            return verified

        } catch {
            print("⚠️ NIP-05: Fetch failed for \(user)@\(domain): \(error.localizedDescription)")
            return false
        }
    }

    /// Cache a verification result
    private func cacheResult(_ key: String, isVerified: Bool) {
        // Evict old entries if cache is full
        if verificationCache.count >= maxCacheSize {
            let oldestKey = verificationCache.min { $0.value.timestamp < $1.value.timestamp }?.key
            if let keyToRemove = oldestKey {
                verificationCache.removeValue(forKey: keyToRemove)
            }
        }

        verificationCache[key] = NIP05CacheEntry(isVerified: isVerified, timestamp: Date())
    }

    /// Clear verification cache
    func clearCache() {
        verificationCache.removeAll()
    }
}

/// Cache entry for NIP-05 verification results
private struct NIP05CacheEntry {
    let isVerified: Bool
    let timestamp: Date
}

// MARK: - Lightning Address Verification

/// Verification service for Lightning addresses (lud16)
actor LightningAddressVerifier {

    /// Shared instance for app-wide verification
    static let shared = LightningAddressVerifier()

    /// Cache of verified Lightning addresses
    private var verificationCache: [String: LNURLCacheEntry] = [:]

    /// Cache TTL (15 minutes - shorter than NIP-05 due to service availability)
    private let cacheTTL: TimeInterval = 15 * 60

    /// Verify a Lightning address is valid and optionally matches a pubkey
    /// - Parameters:
    ///   - lud16: The Lightning address (e.g., "user@wallet.com")
    ///   - expectedPubkey: Optional pubkey to verify (from nostrPubkey in LNURL response)
    /// - Returns: LNURL pay request info if valid, nil otherwise
    func verify(lud16: String, expectedPubkey: String? = nil) async -> LNURLPayRequest? {
        let normalizedLud16 = lud16.lowercased().trimmingCharacters(in: .whitespaces)

        // Check cache first
        if let cached = verificationCache[normalizedLud16] {
            if Date().timeIntervalSince(cached.timestamp) < cacheTTL {
                // If we need to verify pubkey, check it
                if let expectedPubkey = expectedPubkey?.lowercased() {
                    if cached.payRequest?.nostrPubkey?.lowercased() != expectedPubkey {
                        return nil  // Pubkey doesn't match
                    }
                }
                return cached.payRequest
            }
            // Expired
            verificationCache.removeValue(forKey: normalizedLud16)
        }

        // Parse Lightning address
        guard let (user, domain) = parseLightningAddress(normalizedLud16) else {
            return nil
        }

        // Fetch LNURL pay request
        let payRequest = await fetchLNURLPayRequest(user: user, domain: domain)

        // Cache result
        verificationCache[normalizedLud16] = LNURLCacheEntry(payRequest: payRequest, timestamp: Date())

        // Verify pubkey if provided
        if let expectedPubkey = expectedPubkey?.lowercased(),
           let nostrPubkey = payRequest?.nostrPubkey?.lowercased() {
            if nostrPubkey != expectedPubkey {
                print("⚠️ LNURL: nostrPubkey mismatch for \(normalizedLud16)")
                return nil
            }
        }

        return payRequest
    }

    /// Check if a Lightning address is reachable (without pubkey verification)
    func isReachable(lud16: String) async -> Bool {
        return await verify(lud16: lud16) != nil
    }

    /// Parse Lightning address into user and domain
    private func parseLightningAddress(_ lud16: String) -> (user: String, domain: String)? {
        let parts = lud16.split(separator: "@")
        guard parts.count == 2 else { return nil }

        let user = String(parts[0])
        let domain = String(parts[1])

        guard !user.isEmpty, domain.contains(".") else { return nil }

        return (user, domain)
    }

    /// Fetch LNURL pay request from Lightning address
    private func fetchLNURLPayRequest(user: String, domain: String) async -> LNURLPayRequest? {
        // LNURL-pay spec: https://domain/.well-known/lnurlp/user
        let urlString = "https://\(domain)/.well-known/lnurlp/\(user)"
        guard let url = URL(string: urlString) else {
            print("⚠️ LNURL: Invalid URL: \(urlString)")
            return nil
        }

        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("⚠️ LNURL: HTTP error for \(user)@\(domain)")
                return nil
            }

            let decoder = JSONDecoder()
            let payRequest = try decoder.decode(LNURLPayRequest.self, from: data)

            // Verify it's a valid pay request
            guard payRequest.tag == "payRequest",
                  payRequest.callback != nil else {
                print("⚠️ LNURL: Invalid pay request for \(user)@\(domain)")
                return nil
            }

            print("✅ LNURL: Verified \(user)@\(domain)")
            return payRequest

        } catch {
            print("⚠️ LNURL: Fetch failed for \(user)@\(domain): \(error.localizedDescription)")
            return nil
        }
    }

    /// Clear verification cache
    func clearCache() {
        verificationCache.removeAll()
    }
}

/// LNURL-pay request response
struct LNURLPayRequest: Codable {
    let tag: String?
    let callback: String?
    let minSendable: Int64?
    let maxSendable: Int64?
    let metadata: String?
    let commentAllowed: Int?
    let nostrPubkey: String?  // Optional: NIP-57 zap-enabled services include this
    let allowsNostr: Bool?

    /// Minimum amount in sats
    var minSats: Int {
        return Int((minSendable ?? 1000) / 1000)
    }

    /// Maximum amount in sats
    var maxSats: Int {
        return Int((maxSendable ?? 100000000000) / 1000)
    }
}

/// Cache entry for LNURL verification
private struct LNURLCacheEntry {
    let payRequest: LNURLPayRequest?
    let timestamp: Date
}

// MARK: - Combined Profile Verification

/// Combined verification helper for profiles
struct ProfileVerification {

    /// Verify a profile's NIP-05 address
    /// - Parameter profile: The profile to verify
    /// - Returns: True if NIP-05 is verified
    static func verifyNIP05(_ profile: Profile) async -> Bool {
        guard let nip05 = profile.nip05, !nip05.isEmpty else {
            return false
        }
        return await NIP05Verifier.shared.verify(nip05: nip05, pubkey: profile.pubkey)
    }

    /// Verify a profile's Lightning address
    /// - Parameter profile: The profile to verify
    /// - Returns: LNURL pay request if valid
    static func verifyLightningAddress(_ profile: Profile) async -> LNURLPayRequest? {
        guard let lud16 = profile.lud16, !lud16.isEmpty else {
            return nil
        }
        // Optionally verify the LNURL nostrPubkey matches the profile pubkey
        return await LightningAddressVerifier.shared.verify(lud16: lud16, expectedPubkey: profile.pubkey)
    }

    /// Verify a Lightning address belongs to a specific pubkey
    /// - Parameters:
    ///   - lud16: The Lightning address
    ///   - pubkey: The expected owner pubkey
    /// - Returns: True if the Lightning service confirms the pubkey
    static func verifyLightningOwnership(lud16: String, pubkey: String) async -> Bool {
        guard let payRequest = await LightningAddressVerifier.shared.verify(lud16: lud16, expectedPubkey: pubkey) else {
            return false
        }
        // Only return true if the service explicitly confirms the pubkey
        return payRequest.nostrPubkey?.lowercased() == pubkey.lowercased()
    }
}
