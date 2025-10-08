//
//  nostrTVApp.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import SwiftUI

@main
struct StreamViewerApp: App {
    @StateObject private var authManager = NostrAuthManager()

    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView()
                    .environmentObject(authManager)
            } else if authManager.currentUser != nil {
                // User has entered npub but hasn't logged in yet
                ProfileConfirmationView(authManager: authManager)
            } else {
                // No user, show welcome screen
                WelcomeView(authManager: authManager)
            }
        }
    }
}
