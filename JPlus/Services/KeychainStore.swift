import Foundation
import Security

/// Minimal generic-password wrapper around the Security framework.
///
/// Prefers the data-protection keychain (no ACL prompts, sandbox friendly).
/// Ad-hoc "Sign to Run Locally" builds lack the entitlements for it, so every
/// operation also covers the legacy file-based keychain: writes fall back to
/// it, reads check both, deletes clear both.
nonisolated struct KeychainStore: Sendable {
    let service: String
    let account: String

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    func save(_ data: Data) throws {
        var lastStatus = errSecSuccess
        for useDataProtection in [true, false] {
            var query = baseQuery(useDataProtection: useDataProtection)
            let attributes: [String: Any] = [kSecValueData as String: data]

            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                query[kSecValueData as String] = data
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(query as CFDictionary, nil)
            }

            if status == errSecSuccess { return }
            lastStatus = status
            // Only a missing entitlement justifies trying the legacy keychain.
            guard status == errSecMissingEntitlement else { break }
        }
        throw KeychainError.unexpectedStatus(lastStatus)
    }

    func load() throws -> Data? {
        for useDataProtection in [true, false] {
            var query = baseQuery(useDataProtection: useDataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                return item as? Data
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw KeychainError.unexpectedStatus(status)
            }
        }
        return nil
    }

    func delete() throws {
        for useDataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(useDataProtection: useDataProtection) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }

    // MARK: - Private

    private func baseQuery(useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}
