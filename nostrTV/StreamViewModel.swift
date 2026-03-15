import Foundation

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
    private var deletedStreamAddresses: Set<String> = [] // Tracks kind 5 deletions

    // Active subscription tracking
    private var adminFollowSubscriptionId: String?
    private var profilesSubscriptionId: String? // kind 0 - filtered by authors, limit 30
    private var streamsSubscriptionId: String?  // kind 30311 - unfiltered, pipeline handles filtering
    private var deletionsSubscriptionId: String? // kind 5 - stream deletion events

    // Stream collection size limit to prevent unbounded memory growth
    private let maxStreamCount = 200

    // MARK: - zap.stream Filtering Pipeline Constants

    /// Maximum age for stream events (24 hours)
    private static let maxStreamAgeSeconds: TimeInterval = 24 * 60 * 60

    /// Check if a URL is a playable stream URL (matches zap.stream's canPlayUrl)
    private static func canPlayURL(_ url: String) -> Bool {
        guard !url.isEmpty,
              !url.contains("localhost"),
              !url.contains("127.0.0.1"),
              let components = URLComponents(string: url) else { return false }
        return components.path.contains(".m3u8") || components.scheme == "moq"
    }

    /// Check if a stream has any playable URL (streaming or recording)
    private static func canPlayStream(_ stream: Stream) -> Bool {
        return canPlayURL(stream.streaming_url) ||
               (stream.recording != nil && canPlayURL(stream.recording!))
    }

    /// Check if a stream event is within the 24-hour age window
    private static func isWithinAgeWindow(_ stream: Stream) -> Bool {
        guard let createdAt = stream.createdAt else { return false }
        return Date().timeIntervalSince(createdAt) < maxStreamAgeSeconds
    }

    // Use AdminConfig for curated Discover feed (supports multi-admin)
    private var adminPubkey: String {
        return AdminConfig.primaryAdmin
    }

    /// Expose the NostrSDKClient for use by other components
    var sdkClient: NostrSDKClient {
        return nostrSDKClient
    }

    /// Get the featured stream for Following tab (live stream with most viewers from pipeline-filtered streams)
    var featuredStream: Stream? {
        let liveStreams = categorizedStreams.flatMap { $0.streams }.filter { $0.isLive }
        return liveStreams.max(by: { $0.viewerCount < $1.viewerCount })
    }

    /// Get the featured stream for Discover tab (live stream with most viewers from pipeline-filtered streams)
    var discoverFeaturedStream: Stream? {
        let liveStreams = allCategorizedStreams.flatMap { $0.streams }.filter { $0.isLive }
        return liveStreams.max(by: { $0.viewerCount < $1.viewerCount })
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
        // Handle incoming streams — NIP-33 dedup (eventAuthorPubkey + d-tag)
        nostrSDKClient.onStreamReceived = { [weak self] stream in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Mark that we've received at least one stream
                if self.isInitialLoad {
                    self.isInitialLoad = false
                    print("✅ First stream received, ending initial load state")
                }

                print("📺 Stream received: \(stream.streamID) (status: \(stream.status), live: \(stream.isLive))")

                // Skip streams that have been deleted via kind 5
                if self.deletedStreamAddresses.contains(stream.aTag) {
                    print("🗑️ Skipping deleted stream: \(stream.aTag)")
                    return
                }

                // NIP-33 dedup: unique by eventAuthorPubkey + d-tag (streamID), keep newest
                let deduplicationKey = "\(stream.eventAuthorPubkey ?? ""):\(stream.streamID)"
                if let existingIndex = self.streams.firstIndex(where: {
                    "\($0.eventAuthorPubkey ?? ""):\($0.streamID)" == deduplicationKey
                }) {
                    let existingStream = self.streams[existingIndex]
                    let newDate = stream.createdAt ?? Date.distantPast
                    let existingDate = existingStream.createdAt ?? Date.distantPast

                    if newDate > existingDate {
                        self.streams[existingIndex] = stream
                    }
                } else {
                    self.streams.append(stream)
                }

                // Evict old streams if we exceed the limit
                self.evictOldStreamsIfNeeded()

                self.updateCategorizedStreams()
            }
        }

        // Handle deletion events (kind 5) targeting live streams
        nostrSDKClient.onDeletionReceived = { [weak self] addresses in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.deletedStreamAddresses.formUnion(addresses)
                self.streams.removeAll { addresses.contains($0.aTag) }
                self.updateCategorizedStreams()
                print("🗑️ Removed \(addresses.count) deleted streams")
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

            // Start streams subscription (always unfiltered — pipeline handles filtering)
            self.createStreamsSubscription()

            // Subscribe to deletion events (kind 5 targeting 30311)
            self.deletionsSubscriptionId = self.nostrSDKClient.subscribeToDeletions()

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

    /// Create streams subscription (kind 30311)
    /// Always unfiltered — the zap.stream pipeline handles all filtering client-side
    private func createStreamsSubscription() {
        // Close existing subscription if any
        if let existingSubId = streamsSubscriptionId {
            print("📪 Closing existing streams subscription: \(existingSubId.prefix(8))...")
            nostrSDKClient.closeSubscription(existingSubId)
            streamsSubscriptionId = nil
        }

        streamsSubscriptionId = nostrSDKClient.subscribeToStreams(limit: 50)
        print("✅ Created unfiltered streams subscription: \(streamsSubscriptionId?.prefix(8) ?? "nil")")
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

        // Re-run pipeline with the new admin follow list
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
        if let subId = deletionsSubscriptionId {
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
        // === ZAP.STREAM FILTERING PIPELINE ===
        // Applied uniformly before splitting into Curated/Following tabs

        // Step 1: Age filter — discard events older than 24 hours
        let ageFiltered = streams.filter { Self.isWithinAgeWindow($0) }

        // Step 2: Playability filter — must have valid .m3u8 or moq: URL
        let playable = ageFiltered.filter { Self.canPlayStream($0) }

        // Step 3: Remove deleted streams (kind 5)
        let notDeleted = playable.filter { !deletedStreamAddresses.contains($0.aTag) }

        // Step 4: Status bucketing
        let live = notDeleted
            .filter { $0.status == "live" }
            .sorted { ($0.startsAt ?? $0.createdAt ?? .distantPast) > ($1.startsAt ?? $1.createdAt ?? .distantPast) }

        let ended = notDeleted
            .filter { $0.status == "ended" && $0.recording != nil && !$0.recording!.isEmpty }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }

        // Combine live + ended-with-recording as the clean base
        let cleanBase = live + ended

        print("📊 Pipeline: \(streams.count) raw → \(ageFiltered.count) age → \(playable.count) playable → \(notDeleted.count) not-deleted → \(live.count) live + \(ended.count) ended")

        // Fetch profiles for all streamers in the clean base
        let pubkeys = cleanBase.compactMap { $0.pubkey }
        let uniquePubkeys = Array(Set(pubkeys))
        if !uniquePubkeys.isEmpty {
            nostrSDKClient.requestProfiles(for: uniquePubkeys)
        }

        // === SPLIT INTO TABS ===

        // Discover: filter by admin follow list
        let discoverStreams: [Stream]
        if !adminFollowList.isEmpty {
            discoverStreams = cleanBase.filter { stream in
                guard let pubkey = stream.pubkey else { return false }
                return adminFollowList.contains(pubkey)
            }
        } else {
            discoverStreams = []
        }
        self.allCategorizedStreams = categorizeStreams(discoverStreams)

        // Following: filter by user follow list
        let followingStreams: [Stream]
        if !followList.isEmpty {
            followingStreams = cleanBase.filter { stream in
                guard let pubkey = stream.pubkey else { return false }
                return followList.contains(pubkey)
            }
        } else {
            followingStreams = []
        }
        self.categorizedStreams = categorizeStreams(followingStreams)
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
