import Foundation
import AVFoundation

struct StreamCategory {
    let name: String
    let streams: [Stream]
}

class StreamViewModel: ObservableObject {
    @Published var streams: [Stream] = []
    @Published var categorizedStreams: [StreamCategory] = []
    @Published var allCategorizedStreams: [StreamCategory] = []  // Discover streams (filtered by admin follow list)
    @Published var isLoadingAdminFollowList: Bool = true // Track if we're loading the admin follow list
    @Published var isInitialLoad: Bool = true // Track if this is the initial load (no streams received yet)
    private var nostrSDKClient: NostrSDKClient
    private var legacyNostrClient = NostrClient() // Temporary: for ZapManager until it's migrated
    private var refreshTimer: Timer?
    private var followList: Set<String> = [] // User follow list - Use Set for O(1) lookups
    private var adminFollowList: Set<String> = [] // Admin follow list for Discover tab
    private var validationTasks: Set<String> = [] // Track ongoing validations
    private var adminFollowFetchState = (combined: Set<String>(), count: 0) // Track admin follow list fetching

    // Stream collection size limit to prevent unbounded memory growth
    private let maxStreamCount = 200

    // Hardcoded admin pubkeys for curated Discover feed (primary + backup)
    private let adminPubkeys = [
        "f67a7093fdd829fae5796250cf0932482b1d7f40900110d0d932b5a7fb37755d", // nostrTVadmin (primary)
        "9cb3545c36940d9a2ef86d50d5c7a8fab90310cc898c4344bcfc4c822ff47bca"  // tkay@bitcoindistrict.org (backup)
    ]

    /// Expose the NostrSDKClient for use by other components
    var sdkClient: NostrSDKClient {
        return nostrSDKClient
    }

    /// Expose the legacy NostrClient for backward compatibility (temporary)
    /// TODO: Remove once ZapManager is migrated to NostrSDKClient
    var client: NostrClient {
        return legacyNostrClient
    }

    /// Get the featured stream (live stream with most viewers)
    var featuredStream: Stream? {
        let liveStreams = streams.filter { $0.isLive }
        // If following specific users, prioritize their streams
        if !followList.isEmpty {
            let followedLiveStreams = liveStreams.filter { stream in
                guard let pubkey = stream.pubkey else { return false }
                return followList.contains(pubkey)
            }
            if !followedLiveStreams.isEmpty {
                return followedLiveStreams.max(by: { $0.viewerCount < $1.viewerCount })
            }
        }
        // Otherwise return the stream with most viewers overall
        return liveStreams.max(by: { $0.viewerCount < $1.viewerCount })
    }

    /// Get the featured stream for Discover tab (filtered by admin follow list, most viewers)
    var discoverFeaturedStream: Stream? {
        let filteredStreams: [Stream]
        if !adminFollowList.isEmpty {
            filteredStreams = streams.filter { stream in
                guard let pubkey = stream.pubkey else { return false }
                return adminFollowList.contains(pubkey) && stream.isLive
            }
        } else {
            filteredStreams = streams.filter { $0.isLive }
        }
        return filteredStreams.max(by: { $0.viewerCount < $1.viewerCount })
    }

    init() {
        print("🚀 StreamViewModel: Initializing...")
        // Initialize NostrSDKClient
        do {
            print("🔧 StreamViewModel: Creating NostrSDKClient...")
            self.nostrSDKClient = try NostrSDKClient()
            print("✅ StreamViewModel: NostrSDKClient created successfully")
        } catch {
            print("❌ StreamViewModel: Failed to initialize NostrSDKClient: \(error)")
            fatalError("Failed to initialize NostrSDKClient: \(error)")
        }

        nostrSDKClient.onStreamReceived = { [weak self] stream in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Mark that we've received at least one stream
                if self.isInitialLoad {
                    self.isInitialLoad = false
                    print("✅ First stream received, ending initial load state")
                }

                // Always remove exact duplicates by streamID first
                self.streams.removeAll { existingStream in
                    existingStream.streamID == stream.streamID
                }

                // For live streams, prevent duplicates from the same pubkey
                // Only remove other LIVE streams from the same pubkey, not ended ones
                if stream.isLive, let pubkey = stream.pubkey {
                    self.streams.removeAll { existingStream in
                        existingStream.pubkey == pubkey && existingStream.isLive
                    }
                }

                self.streams.append(stream)

                // Evict old streams if we exceed the limit
                self.evictOldStreamsIfNeeded()

                self.updateCategorizedStreams()

                // Validate stream URL in background
                self.validateStreamURL(stream)
            }
        }

        print("🔧 StreamViewModel init - isLoadingAdminFollowList: \(isLoadingAdminFollowList)")

        // Load cached admin follow list immediately
        loadCachedAdminFollowList()

        print("🔧 After loadCachedAdminFollowList - isLoadingAdminFollowList: \(isLoadingAdminFollowList)")

        // Only fetch fresh admin follow list if cache is missing or old
        let shouldFetchFresh = adminFollowList.isEmpty || shouldRefreshAdminCache()
        if shouldFetchFresh {
            print("🔧 Fetching fresh admin follow list...")
            fetchAdminFollowList()
        } else {
            print("✅ Using cached admin follow list, skipping network fetch")
        }

        startAutoRefresh()
    }

    func updateFollowList(_ newFollowList: [String]) {
        followList = Set(newFollowList) // Convert to Set for O(1) lookups
        // Re-categorize streams with new follow filter
        updateCategorizedStreams()
    }

    deinit {
        stopAutoRefresh()
        nostrSDKClient.disconnect()
        legacyNostrClient.disconnect()
    }

    private func startAutoRefresh() {
        print("🔧 StreamViewModel: Starting auto-refresh...")
        // Initial connection and stream request
        print("🔧 StreamViewModel: Calling nostrSDKClient.connect()...")
        nostrSDKClient.connect()

        // Wait for relay connections to establish before subscribing
        print("⏳ StreamViewModel: Waiting 2 seconds for relay connections...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            print("🔧 StreamViewModel: Calling nostrSDKClient.requestLiveStreams(limit: 50)...")
            self.nostrSDKClient.requestLiveStreams(limit: 50)
        }

        // Also connect legacy client for ZapManager (temporary)
        print("🔧 StreamViewModel: Connecting legacy client...")
        legacyNostrClient.connect()

        // Set up timer for automatic refresh every 30 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshStreams()
        }
        print("✅ StreamViewModel: Auto-refresh started")
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshStreams() {
        // Don't clear existing streams immediately - let new data come in and replace
        nostrSDKClient.disconnect()
        nostrSDKClient.connect()

        // Wait for relay connections to establish before subscribing
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.nostrSDKClient.requestLiveStreams(limit: 50)
        }

        // Also refresh legacy client
        legacyNostrClient.disconnect()
        legacyNostrClient.connect()
    }

    /// Evict oldest ended streams when collection exceeds size limit
    private func evictOldStreamsIfNeeded() {
        guard streams.count > maxStreamCount else { return }

        // Calculate how many streams to remove (remove 20% to avoid frequent evictions)
        let excessCount = streams.count - maxStreamCount
        let removalCount = max(excessCount, Int(Double(maxStreamCount) * 0.2))

        // Separate live and ended streams
        let liveStreams = streams.filter { $0.isLive }
        let endedStreams = streams.filter { !$0.isLive }

        // If we have enough ended streams, remove oldest ones
        if endedStreams.count >= removalCount {
            // Sort ended streams by creation date (oldest first)
            let sortedEndedStreams = endedStreams.sorted { stream1, stream2 in
                guard let date1 = stream1.createdAt, let date2 = stream2.createdAt else {
                    return false
                }
                return date1 < date2
            }

            // Get IDs of streams to remove
            let streamsToRemove = Set(sortedEndedStreams.prefix(removalCount).map { $0.streamID })

            // Remove them from the collection
            streams.removeAll { streamsToRemove.contains($0.streamID) }
        } else {
            // If not enough ended streams, remove all ended streams and some oldest live streams
            let streamsToRemoveFromLive = removalCount - endedStreams.count

            // Keep all ended stream IDs for removal
            var streamsToRemove = Set(endedStreams.map { $0.streamID })

            // Sort live streams by creation date (oldest first)
            let sortedLiveStreams = liveStreams.sorted { stream1, stream2 in
                guard let date1 = stream1.createdAt, let date2 = stream2.createdAt else {
                    return false
                }
                return date1 < date2
            }

            // Add oldest live streams to removal set
            streamsToRemove.formUnion(sortedLiveStreams.prefix(streamsToRemoveFromLive).map { $0.streamID })

            // Remove them from the collection
            streams.removeAll { streamsToRemove.contains($0.streamID) }
        }
    }

    func getProfile(for pubkey: String) -> Profile? {
        return nostrSDKClient.getProfile(for: pubkey)
    }

    private func updateCategorizedStreams() {
        // Update Discover streams (filtered by admin follow list)
        let discoverStreams: [Stream]
        if !adminFollowList.isEmpty {
            discoverStreams = streams.filter { stream in
                guard let pubkey = stream.pubkey else { return false }
                return adminFollowList.contains(pubkey)
            }
        } else {
            // If admin follow list is empty, show nothing (prevents showing all streams)
            discoverStreams = []
        }
        self.allCategorizedStreams = categorizeStreams(discoverStreams)

        // Update Following streams (filtered by user follow list)
        let filteredStreams: [Stream]
        if !followList.isEmpty {
            filteredStreams = streams.filter { stream in
                guard let pubkey = stream.pubkey else { return false }
                return followList.contains(pubkey)
            }
        } else {
            // If follow list is empty, show nothing
            filteredStreams = []
        }

        // Update filtered streams
        self.categorizedStreams = categorizeStreams(filteredStreams)
    }

    private func categorizeStreams(_ streamList: [Stream]) -> [StreamCategory] {
        // Single pass to separate live and ended streams, and group live by category
        var liveStreamsByCategory: [String: [Stream]] = [:]
        var endedStreams: [Stream] = []

        for stream in streamList {
            if stream.isLive {
                liveStreamsByCategory[stream.category, default: []].append(stream)
            } else {
                endedStreams.append(stream)
            }
        }

        // Create categories for live streams, sorted alphabetically
        var categories: [StreamCategory] = []

        // Sort category keys once, then sort streams within each category
        for categoryName in liveStreamsByCategory.keys.sorted() {
            guard let categoryStreams = liveStreamsByCategory[categoryName] else { continue }

            let sortedStreams = categoryStreams.sorted { stream1, stream2 in
                // Sort by creation date (newest first), then by title
                if let date1 = stream1.createdAt, let date2 = stream2.createdAt {
                    return date1 > date2
                }
                return stream1.title < stream2.title
            }
            categories.append(StreamCategory(name: categoryName, streams: sortedStreams))
        }

        // Add past streams category at the bottom if there are any
        if !endedStreams.isEmpty {
            let sortedEndedStreams = endedStreams.sorted { stream1, stream2 in
                // Sort ended streams by creation date (newest first)
                if let date1 = stream1.createdAt, let date2 = stream2.createdAt {
                    return date1 > date2
                }
                return stream1.title < stream2.title
            }
            categories.append(StreamCategory(name: "Past Streams", streams: sortedEndedStreams))
        }

        return categories
    }

    private func validateStreamURL(_ stream: Stream) {
        // Skip if already validating this stream
        guard !validationTasks.contains(stream.streamID) else { return }

        // Skip if URL is a placeholder for ended streams
        guard !stream.streaming_url.hasPrefix("ended://") else { return }

        guard let url = URL(string: stream.streaming_url) else {
            removeInvalidStream(stream)
            return
        }

        validationTasks.insert(stream.streamID)
        // Validating stream (removed verbose logging)

        // Use AVAsset to validate if the URL is actually a playable stream
        Task {
            let asset = AVAsset(url: url)

            do {
                // Try to load the asset's playable property with timeout
                let isPlayable = try await withTimeout(seconds: 15) {
                    try await asset.load(.isPlayable)
                }

                await MainActor.run {
                    self.validationTasks.remove(stream.streamID)
                    if !isPlayable {
                        // Stream not playable (removed verbose logging)
                        self.removeInvalidStream(stream)
                    }
                    // Stream validated (removed verbose logging)
                }
            } catch {
                await MainActor.run {
                    self.validationTasks.remove(stream.streamID)
                    // Stream validation failed (removed verbose logging)
                    self.removeInvalidStream(stream)
                }
            }
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func removeInvalidStream(_ stream: Stream) {
        streams.removeAll { $0.streamID == stream.streamID }
        updateCategorizedStreams()
    }

    private func shouldRefreshAdminCache() -> Bool {
        guard let cacheDate = UserDefaults.standard.object(forKey: "adminFollowListCacheDate") as? Date else {
            return true // No cache date, should fetch
        }
        let cacheAge = Date().timeIntervalSince(cacheDate)
        return cacheAge >= (24 * 60 * 60) // Refresh if older than 24 hours
    }

    private func loadCachedAdminFollowList() {
        // Check if cache exists and when it was last updated
        if let cachedData = UserDefaults.standard.data(forKey: "adminFollowList"),
           let cacheDate = UserDefaults.standard.object(forKey: "adminFollowListCacheDate") as? Date {

            // Cache is valid for 24 hours
            let cacheAge = Date().timeIntervalSince(cacheDate)
            let cacheIsValid = cacheAge < (24 * 60 * 60) // 24 hours in seconds

            do {
                let decoder = JSONDecoder()
                let cachedList = try decoder.decode([String].self, from: cachedData)
                adminFollowList = Set(cachedList)
                isLoadingAdminFollowList = false // Cache loaded, no longer loading
                print("✅ Loaded cached admin follow list with \(cachedList.count) users (age: \(Int(cacheAge/60)) minutes)")

                // Only fetch fresh data if cache is old
                if !cacheIsValid {
                    print("⚠️ Cache is older than 24 hours, will refresh in background")
                }
            } catch {
                print("❌ Failed to decode cached admin follow list")
            }
        }
    }

    private func saveAdminFollowListToCache(_ follows: [String]) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(follows)
            UserDefaults.standard.set(data, forKey: "adminFollowList")
            UserDefaults.standard.set(Date(), forKey: "adminFollowListCacheDate")
            print("✅ Saved admin follow list to cache (\(follows.count) users)")
        } catch {
            print("❌ Failed to encode admin follow list for caching")
        }
    }

    private func fetchAdminFollowList() {
        print("🔧 Fetching admin follow lists from \(adminPubkeys.count) admin accounts...")

        // Reset fetch state
        adminFollowFetchState = (Set<String>(), 0)

        // Setup callback for admin follow list
        nostrSDKClient.onFollowListReceived = { [weak self] follows in
            print("🔧 Admin follow list received! Count: \(follows.count)")
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Combine follows from all admin accounts
                self.adminFollowFetchState.combined.formUnion(follows)
                self.adminFollowFetchState.count += 1

                // If we've received all follow lists, save and update
                if self.adminFollowFetchState.count >= self.adminPubkeys.count {
                    let allFollows = Array(self.adminFollowFetchState.combined)
                    self.adminFollowList = self.adminFollowFetchState.combined
                    self.isLoadingAdminFollowList = false
                    self.saveAdminFollowListToCache(allFollows)
                    self.updateCategorizedStreams()
                    print("✅ Combined \(allFollows.count) unique follows from \(self.adminPubkeys.count) admin accounts")
                }
            }
        }

        // Set a timeout to stop loading after 30 seconds if fetch fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self = self else { return }
            if self.isLoadingAdminFollowList {
                print("⚠️ Admin follow list fetch timeout - stopping loading state")
                self.isLoadingAdminFollowList = false
            }
        }

        // Fetch the admin follow lists from all pubkeys
        for pubkey in adminPubkeys {
            print("🔧 Fetching from admin: \(pubkey.prefix(16))...")
            nostrSDKClient.requestFollowList(for: pubkey)
        }
    }
}
