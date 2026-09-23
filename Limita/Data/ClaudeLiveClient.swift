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
    /// Injectable so tests never touch the real Keychain.
    var accessToken: @Sendable (Date) throws -> String = ClaudeLiveClient.accessToken(now:)

    func fetch(now: Date = Date()) async throws -> LiveReading {
        let token = try accessToken(now)

        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return try Self.reading(fromResponse: data, capturedAt: now)
        case 401, 403:
            throw FetchError(message: "Claude rejected the token — open Claude Code to refresh the login")
        case 429:
            throw FetchError(message: "Claude is rate-limiting usage requests")
        default:
            throw FetchError(message: "Claude usage API returned \(status)")
        }
    }

    static func reading(fromResponse data: Data, capturedAt: Date) throws -> LiveReading {
        let usage = try JSONDecoder().decode(Usage.self, from: data)
        let snapshot = LimitSnapshot(
            fiveHour: usage.fiveHour?.limitWindow,
            sevenDay: usage.sevenDay?.limitWindow,
            capturedAt: capturedAt
        )
        guard !snapshot.isEmpty else {
            throw FetchError(message: "Claude usage API returned no limit windows")
        }

        var details = AccountDetails()
        details.claudeUsageCredits = usage.spend?.usageCredits
        details.cloudCredits = usage.cloudCredits?.allowance
        return LiveReading(snapshot: snapshot, details: details)
    }

    // MARK: - Credentials

    static func accessToken(now: Date) throws -> String {
        guard let data = keychainCredentials() ?? fileCredentials() else {
            throw FetchError(message: "Not signed in to Claude Code — sign in there first")
        }
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              let oauth = credentials.claudeAiOauth,
              !oauth.accessToken.isEmpty
        else {
            throw FetchError(message: "Could not read the Claude Code login")
        }
        if let expiresAt = oauth.expiresAt, Date(timeIntervalSince1970: expiresAt / 1000) <= now {
            throw FetchError(message: "Claude Code login expired — open Claude Code to refresh it")
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
        let spend: Spend?
        /// Cloud session credits. The key is an internal code name, so it may change;
        /// the row then disappears instead of breaking the parse.
        let cloudCredits: DollarWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case spend
            case cloudCredits = "iguana_necktie"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try container.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try container.decodeIfPresent(Window.self, forKey: .sevenDay)
            // Extras must never cost us the limits themselves.
            spend = try? container.decodeIfPresent(Spend.self, forKey: .spend)
            cloudCredits = try? container.decodeIfPresent(DollarWindow.self, forKey: .cloudCredits)
        }
    }

    /// Usage credits that cover requests past the plan limits.
    private struct Spend: Decodable {
        let enabled: Bool?
        let used: Money?
        let limit: Money?
        let balance: Money?

        var usageCredits: AccountDetails.UsageCredits? {
            if let balance = balance?.dollars { return .balance(dollars: balance) }
            if enabled == false { return .off }
            guard let used = used?.dollars else { return nil }
            return .spent(dollars: used, limit: limit?.dollars)
        }
    }

    /// `{"amount_minor": 1234, "currency": "USD", "exponent": 2}`, or a plain number.
    private struct Money: Decodable {
        let dollars: Double?

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(Double.self) {
                dollars = value
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let minor = try container.decodeIfPresent(Double.self, forKey: .amountMinor)
            let exponent = try container.decodeIfPresent(Int.self, forKey: .exponent) ?? 2
            dollars = minor.map { $0 / pow(10, Double(exponent)) }
        }

        enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor"
            case exponent
        }
    }

    private struct DollarWindow: Decodable {
        let limitDollars: Double?
        let remainingDollars: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case limitDollars = "limit_dollars"
            case remainingDollars = "remaining_dollars"
            case resetsAt = "resets_at"
        }

        var allowance: AccountDetails.Allowance? {
            guard let remainingDollars else { return nil }
            return .init(
                remaining: remainingDollars,
                limit: limitDollars,
                expiresAt: resetsAt.flatMap(ISO8601DateFormatter.parseFlexible)
            )
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
