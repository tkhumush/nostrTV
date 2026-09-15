//
//  nostrTVApp.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI

@main
struct StreamViewerApp: App {
    // Single shared NostrSDKClient for the whole app. All managers and views
    // that need relay access receive this instance via injection instead of
    // creating their own relay pools.
    private let sharedNostrClient: NostrSDKClient

    @StateObject private var authManager: NostrAuthManager

    init() {
        // Create the shared client once. If relay pool creation fails we fall
        // back to an error-state client rather than crashing the app.
        var client: NostrSDKClient
        do {
            client = try NostrSDKClient()
        } catch {
            print("❌ Failed to initialize shared NostrSDKClient: \(error)")
            client = NostrSDKClient.errorClient(message: "Failed to initialize relay pool: \(error.localizedDescription)")
        }
        self.sharedNostrClient = client

        // Inject the shared client into the auth manager so it shares the same
        // relay pool as the rest of the app (fixes Bug #14 profile-loading race).
        self._authManager = StateObject(wrappedValue: NostrAuthManager(nostrSDKClient: client))
    }

    var body: some Scene {
        WindowGroup {
            // Always show ContentView - login is now optional via Following tab
            ContentView(nostrSDKClient: sharedNostrClient)
                .environmentObject(authManager)
        }
    }
}
