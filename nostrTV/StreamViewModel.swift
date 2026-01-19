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
    private var followList: Set<String> = [] // User follow list - Use Set for O(1) lookups
    private var adminFollowList: Set<String> = [] // Admin follow list for Discover tab
    private var validationTasks: Set<String> = [] // Track ongoing validations

    // Active subscription tracking
    private var adminFollowSubscriptionId: String?
    private var profilesSubscriptionId: String? // kind 0 - filtered by authors, limit 30
    private var streamsSubscriptionId: String?  // kind 30311 - no author filter, limit 50

    // Stream collection size limit to prevent unbounded memory growth
    private let maxStreamCount = 200

    // Primary admin pubkey for curated Discover feed
    private let adminPubkey = "a4a9df1630ef1b2f22b3c5ba56a14773c2b99f7a9eafaca30d7d6f90767acd9f"

    /// Expose the NostrSDKClient for use by other components
    var sdkClient: NostrSDKClient {
        return nostrSDKClient
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

        setupCallbacks()

        print("🔧 StreamViewModel init - isLoadingAdminFollowList: \(isLoadingAdminFollowList)")

        // Load cached admin follow list immediately
        loadCachedAdminFollowList()

        print("🔧 After loadCachedAdminFollowList - isLoadingAdminFollowList: \(isLoadingAdminFollowList)")

        // Connect and start subscriptions
        startSubscriptions()
    }

    // MARK: - Callback Setup

    private func setupCallbacks() {
        // Handle incoming streams
        nostrSDKClient.onStreamReceived = { [weak self] stream in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Mark that we've received at least one stream
                if self.isInitialLoad {
                    self.isInitialLoad = false
                    print("✅ First stream received, ending initial load state")
                }

                // Filter to only show live streams (client-side filter since SDK doesn't support multi-char tag filters)
                guard stream.isLive else {
                    print("⏭️ Skipping ended stream: \(stream.streamID) (status: \(stream.status))")
                    return
                }

                guard let pubkey = stream.pubkey else {
                    print("⚠️ Stream has no pubkey, skipping: \(stream.streamID)")
                    return
                }

                // Check if we already have a stream from this pubkey
                if let existingIndex = self.streams.firstIndex(where: { $0.pubkey == pubkey }) {
                    let existingStream = self.streams[existingIndex]

                    // Compare dates - keep only the most recent stream per pubkey
                    let newDate = stream.createdAt ?? Date.distantPast
                    let existingDate = existingStream.createdAt ?? Date.distantPast

                    if newDate > existingDate {
                        // New stream is more recent - replace the old one
                        self.streams.remove(at: existingIndex)
                        self.streams.append(stream)
                        self.validateStreamURL(stream)
                    }
                    // If existing stream is newer, ignore this one
                } else {
                    // No existing stream from this pubkey - add it
                    self.streams.append(stream)
                    self.validateStreamURL(stream)
                }

                // Evict old streams if we exceed the limit
                self.evictOldStreamsIfNeeded()

                self.updateCategorizedStreams()
            }
        }

        // Handle follow list received (for admin follow list fetch)
        nostrSDKClient.onFollowListReceived = { [weak self] follows in
            DispatchQueue.main.async {
                self?.handleAdminFollowListReceived(follows)
            }
        }
    }

    // MARK: - Subscription Management

    private func startSubscriptions() {
        print("🔧 StreamViewModel: Starting subscriptions...")
        nostrSDKClient.connect()

        // Wait for relay connections to establish
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            // Start streams subscription immediately (no author filter, filter client-side)
            self.createStreamsSubscription()

            // If we have cached admin follow list, create profiles subscription
            if !self.adminFollowList.isEmpty {
                print("✅ Using cached admin follow list, creating profiles subscription...")
                self.createProfilesSubscription(authors: Array(self.adminFollowList))
            }

            // Only fetch fresh admin follow list if cache is missing or old
            let shouldFetchFresh = self.adminFollowList.isEmpty || self.shouldRefreshAdminCache()
            if shouldFetchFresh {
                print("🔧 Fetching fresh admin follow list...")
                self.fetchAdminFollowList()
            } else {
                print("✅ Using cached admin follow list, skipping network fetch")
            }
        }
    }

    /// Create streams subscription (kind 30311) - no author filter, filter client-side
    private func createStreamsSubscription() {
        // Close existing subscription if any
        if let existingSubId = streamsSubscriptionId {
            print("📪 Closing existing streams subscription: \(existingSubId.prefix(8))...")
            nostrSDKClient.closeSubscription(existingSubId)
            streamsSubscriptionId = nil
        }

        // Subscribe to all streams, filter by admin follow list client-side
        streamsSubscriptionId = nostrSDKClient.subscribeToStreams(limit: 50)
        print("✅ Created streams subscription: \(streamsSubscriptionId?.prefix(8) ?? "nil")")
    }

    /// Create profiles subscription (kind 0) filtered by author list
    private func createProfilesSubscription(authors: [String]) {
        guard !authors.isEmpty else {
            print("⚠️ Cannot create profiles subscription with empty author list")
            return
        }

        // Close existing subscription if any
        if let existingSubId = profilesSubscriptionId {
            print("📪 Closing existing profiles subscription: \(existingSubId.prefix(8))...")
            nostrSDKClient.closeSubscription(existingSubId)
            profilesSubscriptionId = nil
        }

        // Profiles subscription - limit 30
        profilesSubscriptionId = nostrSDKClient.subscribeToProfiles(authors: authors)
        print("✅ Created profiles subscription for \(authors.count) authors: \(profilesSubscriptionId?.prefix(8) ?? "nil")")
    }

    /// Fetch admin follow list (kind 3) - fetch once then close
    private func fetchAdminFollowList() {
        print("🔧 Fetching admin follow list from primary admin...")

        // Subscribe to admin's follow list
        adminFollowSubscriptionId = nostrSDKClient.subscribeToFollowList(for: adminPubkey)
        print("✅ Subscribed to admin follow list: \(adminFollowSubscriptionId?.prefix(8) ?? "nil")")

        // Set a timeout to stop loading after 30 seconds if fetch fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self = self else { return }
            if self.isLoadingAdminFollowList {
                print("⚠️ Admin follow list fetch timeout - stopping loading state")
                self.isLoadingAdminFollowList = false
            }
        }
    }

    /// Handle received admin follow list
    private func handleAdminFollowListReceived(_ follows: [String]) {
        print("🔧 Admin follow list received! Count: \(follows.count)")

        // Close the admin follow list subscription - we only need it once
        if let subId = adminFollowSubscriptionId {
            print("📪 Closing admin follow list subscription (received data): \(subId.prefix(8))...")
            nostrSDKClient.closeSubscription(subId)
            adminFollowSubscriptionId = nil
        }

        // Update admin follow list
        adminFollowList = Set(follows)
        isLoadingAdminFollowList = false
        saveAdminFollowListToCache(follows)

        // Create/update profiles subscription with the follow list
        let combinedAuthors = getCombinedAuthorList()
        createProfilesSubscription(authors: combinedAuthors)

        updateCategorizedStreams()
        print("✅ Admin follow list processed: \(follows.count) users")
    }

    // MARK: - User Follow List Updates

    /// Update user follow list (called when user logs in)
    func updateFollowList(_ newFollowList: [String]) {
        let previousFollowList = followList
        followList = Set(newFollowList)

        print("🔧 User follow list updated: \(newFollowList.count) users")

        // If follow list actually changed, recreate profiles subscription with combined authors
        if followList != previousFollowList && !followList.isEmpty {
            let combinedAuthors = getCombinedAuthorList()
            createProfilesSubscription(authors: combinedAuthors)
        }

        // Re-categorize streams with new follow filter
        updateCategorizedStreams()
    }

    /// Get combined author list (admin follows + user follows, deduplicated)
    private func getCombinedAuthorList() -> [String] {
        var combined = adminFollowList
        combined.formUnion(followList)
        return Array(combined)
    }

    deinit {
        // Close all active subscriptions
        if let subId = profilesSubscriptionId {
            nostrSDKClient.closeSubscription(subId)
        }
        if let subId = streamsSubscriptionId {
            nostrSDKClient.closeSubscription(subId)
        }
        if let subId = adminFollowSubscriptionId {
            nostrSDKClient.closeSubscription(subId)
        }
        nostrSDKClient.disconnect()
    }

    // MARK: - Stream Management

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

    // MARK: - Stream URL Validation

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
                        self.removeInvalidStream(stream)
                    }
                }
            } catch {
                await MainActor.run {
                    self.validationTasks.remove(stream.streamID)
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

    // MARK: - Cache Management

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
}
