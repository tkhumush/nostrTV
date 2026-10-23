import SwiftUI

/// Each app owns one relay pool; both platforms compile the same services.
@main
struct CoveIOSApp: App {
    private let client: NostrSDKClient
    @StateObject private var auth: NostrAuthManager

    init() {
        let client: NostrSDKClient
        do {
            #if DEBUG
            client = CoveUITestSupport.enabled ? try NostrSDKClient(relayURLs: []) : try NostrSDKClient()
            #else
            client = try NostrSDKClient()
            #endif
        } catch {
            client = NostrSDKClient.errorClient(message: error.localizedDescription)
        }
        self.client = client
        let auth = NostrAuthManager(nostrSDKClient: client)
        #if DEBUG
        if CoveUITestSupport.enabled {
            UserDefaults.standard.set(true, forKey: "cove.showChat")
            if ProcessInfo.processInfo.arguments.contains("--cove-ui-authenticated") {
                // A presentation fixture only. It has no signing method and never persists a session.
                auth.isAuthenticated = true
                auth.currentProfile = CoveUITestSupport.streams.first?.profile
            }
        }
        #endif
        _auth = StateObject(wrappedValue: auth)
    }

    var body: some Scene {
        WindowGroup {
            PhoneContentView(client: client)
                .environmentObject(auth)
                .tint(.coveAccent)
                .preferredColorScheme(.dark)
        }
    }
}
