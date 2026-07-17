import Foundation
import Security

// =================================================================
// PasswordKeychain — sole storage for `.email` account passwords.
//
// Pre-Phase-3, KiddoAccount.password lived in plaintext inside
// `accounts.json`. Phase 3 moves it to the macOS Keychain, keyed by
// the KiddoAccount's UUID so:
//
//   - Two Kiddo accounts using the same provider login don't collide.
//   - Renaming `username` doesn't lose the password mapping.
//   - Deleting a Kiddo account also removes its keychain entry.
//
// Items are stored as kSecClassGenericPassword with
//   kSecAttrService = "org.axiom.AxiomKiddo"
//   kSecAttrAccount = <KiddoAccount.id.uuidString>
//   kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock
//
// First-unlock accessibility lets the menu-bar worker poll POP3 /
// send SMTP after a reboot without a keychain prompt. The item is
// still protected by the user account password — keychain.db is
// encrypted at rest.
// =================================================================

enum PasswordKeychain {
    /// Service identifier shared by every Kiddo password entry.
    /// Picked once and stable forever — changing it would orphan
    /// previously-stored items.
    static let service = "org.axiom.AxiomKiddo"

    enum KError: Error, LocalizedError {
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .osStatus(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
                return "Keychain error \(s): \(msg)"
            }
        }
    }

    /// Insert or overwrite the password for one Kiddo account.
    /// Uses update-then-add so the second save of the same account
    /// doesn't fail with `errSecDuplicateItem`.
    static func set(id: UUID, password: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break  // fall through to insert
        default:
            throw KError.osStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        if insertStatus != errSecSuccess {
            throw KError.osStatus(insertStatus)
        }
    }

    /// Fetch the password for one Kiddo account, or `nil` if no entry
    /// exists. Returns `nil` on any Keychain error so the worker can
    /// keep running with no password (it'll fail at AUTH PLAIN with a
    /// surfaceable 535 instead of crashing).
    static func get(id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    /// Remove a password from the keychain. Idempotent — missing
    /// entries are silently ignored. Called from
    /// `AccountStore.remove` so deleting a Kiddo account doesn't
    /// leave orphan keychain items.
    static func delete(id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
