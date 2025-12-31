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
            // Always show ContentView - login is now optional via Following tab
            ContentView()
                .environmentObject(authManager)
        }
    }
}
