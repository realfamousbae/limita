import Foundation
import Security

/// Fetches current Claude rate limits with Claude Code's own OAuth login.
///
/// This uses `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind
/// Claude Code's `/usage` screen. It is **undocumented** and may change without notice;
/// the status-line capture remains the fallback.
///
/// The access token is read from Claude Code's Keychain item (macOS asks the user once)
/// and is only ever sent to api.anthropic.com. It is never stored or refreshed by
/// Limita: refreshing would rotate the token under Claude Code's feet.
struct ClaudeLiveClient: Sendable {
    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    var timeout: TimeInterval = 20

    func fetch(now: Date = Date()) async throws -> LimitSnapshot {
        let token = try Self.accessToken(now: now)

        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return try Self.snapshot(fromResponse: data, capturedAt: now)
        case 401, 403:
            throw FetchError(message: "Claude отклонил токен — откройте Claude Code, чтобы он обновил вход")
        case 429:
            throw FetchError(message: "Claude временно ограничил запросы лимитов")
        default:
            throw FetchError(message: "Claude usage API ответил \(status)")
        }
    }

    static func snapshot(fromResponse data: Data, capturedAt: Date) throws -> LimitSnapshot {
        let usage = try JSONDecoder().decode(Usage.self, from: data)
        let snapshot = LimitSnapshot(
            fiveHour: usage.fiveHour?.limitWindow,
            sevenDay: usage.sevenDay?.limitWindow,
            capturedAt: capturedAt
        )
        guard !snapshot.isEmpty else {
            throw FetchError(message: "Claude usage API не вернул окна лимитов")
        }
        return snapshot
    }

    // MARK: - Credentials

    static func accessToken(now: Date) throws -> String {
        guard let data = keychainCredentials() ?? fileCredentials() else {
            throw FetchError(message: "Нет входа Claude Code — выполните вход в Claude Code")
        }
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              let oauth = credentials.claudeAiOauth,
              !oauth.accessToken.isEmpty
        else {
            throw FetchError(message: "Не удалось прочитать вход Claude Code")
        }
        if let expiresAt = oauth.expiresAt, Date(timeIntervalSince1970: expiresAt / 1000) <= now {
            throw FetchError(message: "Вход Claude Code истёк — откройте Claude Code, чтобы он обновился")
        }
        return oauth.accessToken
    }

    private static func keychainCredentials() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Claude Code falls back to a file where no Keychain is available.
    private static func fileCredentials() -> Data? {
        try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json"))
    }

    private struct Credentials: Decodable {
        let claudeAiOauth: OAuth?

        struct OAuth: Decodable {
            let accessToken: String
            /// Milliseconds since 1970.
            let expiresAt: Double?
        }
    }

    // MARK: - Wire format

    private struct Usage: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct Window: Decodable {
        /// Percent, 0...100.
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var limitWindow: LimitWindow? {
            guard let utilization, utilization.isFinite else { return nil }
            return LimitWindow(
                usedPercent: utilization,
                resetsAt: resetsAt.flatMap(ISO8601DateFormatter.parseFlexible)
            )
        }
    }
}
