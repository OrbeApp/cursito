import Foundation
import Security

/// A generic password in the login keychain.
struct KeychainItem: Sendable {
    let service: String
    let account: String

    static let cursorAdminAPIKey = KeychainItem(service: "com.orbeapp.cursito", account: "cursor-admin-api-key")

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else {
            if status != errSecSuccess { throw KeychainError(status: status) }
            return
        }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Cursito: Cursor Admin API key"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus != errSecSuccess { throw KeychainError(status: addStatus) }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
