import Foundation
import Security

/// Where a secret is kept: the Keychain in the app, memory in tests.
protocol SecretStoring: Sendable {
    func read() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

/// A secret Limita keeps for itself in the login Keychain, such as the DeepSeek API key.
/// Stored as a generic password; never logged and never written to any other file.
///
/// Limita's builds are signed ad hoc, so after an update macOS may ask once more whether
/// Limita may read its own item ("Always Allow").
struct KeychainStore: SecretStoring {
    struct KeychainError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let service: String
    var account = "api-key"

    /// The DeepSeek API key. Fake runs (`LIMITA_DEEPSEEK_API`) use an item of their own,
    /// so trying the fake server never touches the real key.
    static let deepseek = KeychainStore(
        service: DeepSeekClient.apiOverride == nil ? "com.limita.app.deepseek" : "com.limita.fake.deepseek"
    )

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored secret, `nil` when there is none.
    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status, doing: "read")
        }
    }

    /// Stores `value`, replacing any earlier one.
    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrLabel as String] = "Limita (\(account))"
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw Self.error(added, doing: "save") }
        default:
            throw Self.error(update, doing: "save")
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, doing: "remove") }
    }

    private static func error(_ status: OSStatus, doing action: String) -> KeychainError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            KeychainError(message: "macOS did not let Limita \(action) its key in the Keychain — press Refresh and choose Always Allow")
        default:
            KeychainError(message: "Could not \(action) the key in the Keychain (\(status))")
        }
    }
}

/// A 429 from any service's API, with the wait it asked for. `LimitsStore` backs off
/// from the service on any of them.
protocol RateLimitedError: LocalizedError {
    var retryAfter: TimeInterval? { get }
}

extension ClaudeLiveClient.RateLimited: RateLimitedError {}
