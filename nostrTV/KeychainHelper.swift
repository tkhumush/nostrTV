import Foundation
import Security

/// Secrets use app-scoped, non-synchronizing, device-bound Keychain items.
protocol CredentialStore {
    func save(_ data: Data, account: String) -> Bool
    func load(account: String) -> Data?
    func delete(account: String) -> Bool
}

struct KeychainStore: CredentialStore {
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.nostrtv.app") {
        self.service = service
    }

    private func query(account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: account,
         kSecAttrSynchronizable: false]
    }

    func save(_ data: Data, account: String) -> Bool {
        let identity = query(account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // Update in place: a failed write must not first destroy the saved key.
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    func load(account: String) -> Data? {
        var request = query(account: account)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(account: String) -> Bool {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum KeychainHelper {
    static let nsecAccount = "nostrNsecPrivateKey"
    static let bunkerAccount = "nostrBunkerSession"
}
