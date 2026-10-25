import Foundation
import Security
import Testing
import UIKit
@testable import CoveIOS

/// An operator must lock/unlock a passcode-protected physical iPhone when prompted.
/// Opt in only in the separate audit app; ordinary test runs never wait for input.
@MainActor
struct HardwareCredentialTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COVE_TEST_DEVICE_LOCK"] == "1"))
    func keychainRequiresAnUnlockedPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        Issue.record("The lock test must run on physical hardware, not a simulator.")
        #else
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        try #require(bundleID.hasSuffix(".securityaudit"), "Use the isolated audit app.")
        let app = UIApplication.shared
        try #require(app.isProtectedDataAvailable, "Unlock the iPhone before starting.")
        let service = bundleID + ".hardware-keychain-test"
        let account = "generated-lock-probe"
        let store = KeychainStore(service: service)
        try #require(store.delete(account: account))
        // This is generated test data, never a user's signing key.
        let fixture = Data(UUID().uuidString.utf8)
        try #require(store.save(fixture, account: account))
        defer { _ = store.delete(account: account) }
        try #require(store.load(account: account) == fixture)

        var expired = false
        let backgroundTask = app.beginBackgroundTask(withName: "Keychain lock audit") {
            expired = true
        }
        try #require(backgroundTask != .invalid, "Could not obtain time to check the locked state.")
        defer { app.endBackgroundTask(backgroundTask) }

        print("AUDIT_LOCK_READY: lock the iPhone now; do not unlock until AUDIT_UNLOCK_READY.")
        try await waitForProtection(available: false, expired: { expired })
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let lockedStatus = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(lockedStatus == errSecInteractionNotAllowed,
                "A locked read must be denied, not succeed or merely report a missing item.")
        #expect(result == nil)
        #expect(store.load(account: account) == nil)
        print("AUDIT_UNLOCK_READY: locked read checked; unlock the iPhone now.")
        try await waitForProtection(available: true, expired: { expired })
        #expect(store.load(account: account) == fixture)
        #expect(store.delete(account: account))
        #expect(store.load(account: account) == nil)
        print("AUDIT_LOCK_FINISHED: unlock read and cleanup checked; inspect the test result for success.")
        #endif
    }

    private func waitForProtection(available: Bool, expired: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        while UIApplication.shared.isProtectedDataAvailable != available {
            try #require(!expired(), "Background execution expired before the hardware check finished.")
            try #require(Date() < deadline, "Timed out waiting for the operator to lock/unlock the iPhone.")
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
