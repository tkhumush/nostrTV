//
//  LoginFlowView.swift
//  nostrTV
//
//  Created by Claude on 4/24/25.
//

import SwiftUI

/// Combined login flow view that handles both NIP-05 entry and profile confirmation
struct LoginFlowView: View {
    @ObservedObject var authManager: NostrAuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if authManager.currentUser != nil {
                // User has entered NIP-05, show profile confirmation
                ProfileConfirmationView(authManager: authManager)
            } else {
                // No user yet, show bunker login directly
                BunkerLoginView(authManager: authManager)
            }
        }
    }
}
