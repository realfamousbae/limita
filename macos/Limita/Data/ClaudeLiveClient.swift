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
///
/// Set `LIMITA_CLAUDE_API` to another origin (see `scripts/fake-api.py`) to test against
/// fake responses. The login is then not read at all, so no token ever goes there.
struct ClaudeLiveClient: Sendable {
    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A 429. `retryAfter` is the wait the server asked for, when it named one.
    struct RateLimited: LocalizedError {
        let retryAfter: TimeInterval?
        var errorDescription: String? { "Claude is rate-limiting usage requests" }
    }

    static let apiOverride = ProcessInfo.processInfo.environment["LIMITA_CLAUDE_API"].flatMap(URL.init(string:))
    private static let api = apiOverride ?? URL(string: "https://api.anthropic.com")!
    static let endpoint = api.appendingPathComponent("api/oauth/usage")
    static let profileEndpoint = api.appendingPathComponent("api/oauth/profile")
    static let keychainService = "Claude Code-credentials"

    /// Claude Code's login: the token, and the plan it saved next to it.
    struct Login: Sendable, Equatable {
        let accessToken: String
        /// "Pro", "Ultra", … as of sign-in; `nil` when the login does not say.
        let plan: String?
    }

    var timeout: TimeInterval = 20
    /// Injectable so tests never touch the real Keychain.
    var login: @Sendable (Date) throws -> Login = { now in
        apiOverride == nil ? try ClaudeLiveClient.login(now: now) : Login(accessToken: "fake", plan: nil)
    }

    func fetch(now: Date = Date()) async throws -> LiveReading {
        let login = try login(now)
        let token = login.accessToken

        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        async let profilePlan = plan(token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            // The login keeps the plan from when the user signed in; the profile is current.
            let plan = await profilePlan ?? login.plan
            let reading = try Self.reading(fromResponse: data, capturedAt: now, plan: plan)
            var details = reading.details
            details.plan = plan
            return LiveReading(snapshot: reading.snapshot, details: details)
        case 401, 403:
            throw FetchError(message: "Claude rejected the login (\(status)) — open Claude Code to renew it")
        case 429:
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            throw RateLimited(retryAfter: header.flatMap { Self.retryAfter($0, now: now) })
        default:
            throw FetchError(message: "Claude usage API returned \(status)")
        }
    }

    /// `Retry-After` in seconds, or as an HTTP date.
    static func retryAfter(_ header: String, now: Date) -> TimeInterval? {
        let value = header.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max($0.timeIntervalSince(now), 0) }
    }

    /// The current plan from `GET /api/oauth/profile`, also undocumented. `nil` on any
    /// failure: the plan is a nicety and must never cost the limits.
    private func plan(token: String) async -> String? {
        var request = URLRequest(url: Self.profileEndpoint, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Self.plan(fromProfile: data)
    }

    /// `{"organization": {"organization_type": "claude_max", "rate_limit_tier":
    /// "default_claude_max_5x"}}` → "Max".
    static func plan(fromProfile data: Data) -> String? {
        guard let organization = try? JSONDecoder().decode(Profile.self, from: data).organization,
              let type = organization.organizationType
        else { return nil }
        let subscription = type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
        return planName(subscription: subscription, tier: organization.rateLimitTier)
    }

    private struct Profile: Decodable {
        let organization: Organization?

        struct Organization: Decodable {
            let organizationType: String?
            let rateLimitTier: String?

            enum CodingKeys: String, CodingKey {
                case organizationType = "organization_type"
                case rateLimitTier = "rate_limit_tier"
            }
        }
    }

    /// A verified Ultra account has no 5-hour limit, and the response no such window. Only
    /// Ultra counts: on other plans the window may be missing merely because it has reset.
    static func reading(fromResponse data: Data, capturedAt: Date, plan: String? = nil) throws -> LiveReading {
        let usage = try JSONDecoder().decode(Usage.self, from: data)
        let snapshot = LimitSnapshot(
            fiveHour: usage.fiveHour?.limitWindow,
            sevenDay: usage.sevenDay?.limitWindow,
            capturedAt: capturedAt,
            hasNoFiveHourLimit: plan == ultraPlan && usage.fiveHour == nil,
            scoped: usage.scopedWindows
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

    static func login(now: Date) throws -> Login {
        guard let data = try keychainCredentials() ?? fileCredentials() else {
            throw FetchError(message: "Not signed in to Claude Code — sign in there first")
        }
        return try login(fromCredentials: data, now: now)
    }

    static func login(fromCredentials data: Data, now: Date) throws -> Login {
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              let oauth = credentials.claudeAiOauth,
              !oauth.accessToken.isEmpty
        else {
            throw FetchError(message: "Could not read the Claude Code login")
        }
        if let expiresAt = oauth.expiresAt.map({ Date(timeIntervalSince1970: $0 / 1000) }), expiresAt <= now {
            // Claude Code renews the token only while it runs; Limita never refreshes it,
            // since that could invalidate Claude Code's own copy.
            let ago = expiresAt.relativeText(to: now)
            throw FetchError(message: "Claude Code login expired \(ago) — open Claude Code to renew it")
        }
        return Login(
            accessToken: oauth.accessToken,
            plan: planName(subscription: oauth.subscriptionType, tier: oauth.rateLimitTier)
        )
    }

    static let ultraPlan = "Ultra"

    /// `"pro"` → "Pro". Max 5x is now called Max and Max 20x Ultra, but logins still say
    /// `"max"` with tier `"default_claude_max_5x"` or `"default_claude_max_20x"`.
    static func planName(subscription: String?, tier: String?) -> String? {
        guard let subscription = subscription?.trimmingCharacters(in: .whitespaces), !subscription.isEmpty else {
            return nil
        }
        let tier = tier?.lowercased()
        if tier?.contains("ultra") == true { return ultraPlan }
        if subscription.lowercased() == "max" {
            return tier?.hasSuffix("_20x") == true ? ultraPlan : "Max"
        }
        var name = subscription.prefix(1).uppercased() + subscription.dropFirst().lowercased()
        if let multiplier = tier?.split(separator: "_").last, multiplier.hasSuffix("x"),
           Int(multiplier.dropLast()) != nil {
            name += " X\(multiplier.dropLast())"
        }
        return name
    }

    /// `nil` when there is no item; throws when there is one but it cannot be read.
    private static func keychainCredentials() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if let error = keychainError(status) { throw error }
        return item as? Data
    }

    static func keychainError(_ status: OSStatus) -> FetchError? {
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return FetchError(message: "Keychain access to the Claude Code login was denied — press Refresh and choose Always Allow")
        default:
            return FetchError(message: "Keychain error \(status) reading the Claude Code login")
        }
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
            /// "pro", "max", … Ultra is still "max".
            let subscriptionType: String?
            /// e.g. "default_claude_max_20x"; tells Ultra from Max.
            let rateLimitTier: String?
        }
    }

    // MARK: - Wire format

    private struct Usage: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let spend: Spend?
        /// Every window again, including the per-model ones (`weekly_scoped`) that have
        /// no key of their own. An entry that fails to decode stays as `nil`, so the
        /// positions `shares` point at still hold.
        let limits: [Limit?]?
        /// How much of the weekly limit each per-model window takes, by its position in
        /// `limits`.
        let shares: [Share]?
        /// Cloud session credits. The key is an internal code name, so it may change;
        /// the row then disappears instead of breaking the parse.
        let cloudCredits: DollarWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case spend
            case limits
            case shares = "weekly_scoped_shares"
            case cloudCredits = "iguana_necktie"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try container.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try container.decodeIfPresent(Window.self, forKey: .sevenDay)
            // Extras must never cost us the limits themselves.
            spend = try? container.decodeIfPresent(Spend.self, forKey: .spend)
            limits = try? container.decodeIfPresent([Lossy<Limit>].self, forKey: .limits)?.map(\.value)
            shares = try? container.decodeIfPresent([Lossy<Share>].self, forKey: .shares)?.compactMap(\.value)
            cloudCredits = try? container.decodeIfPresent(DollarWindow.self, forKey: .cloudCredits)
        }

        /// The per-model windows, each with its share of the weekly limit when reported.
        var scopedWindows: [ScopedWindow] {
            guard let limits else { return [] }
            return limits.indices.compactMap { index in
                guard var window = limits[index]?.scopedWindow else { return nil }
                if window.isWeekly, let share = shares?.first(where: { $0.limitIndex == index }) {
                    window.weeklyShare = share.weeklyShare
                }
                return window
            }
        }
    }

    /// `{"limit_index": 2, "used_percent_of_weekly": 12, "allowance_percent_of_weekly": 50}`.
    private struct Share: Decodable {
        let limitIndex: Int
        let usedPercent: Double
        let allowancePercent: Double?

        enum CodingKeys: String, CodingKey {
            case limitIndex = "limit_index"
            case usedPercent = "used_percent_of_weekly"
            case allowancePercent = "allowance_percent_of_weekly"
        }

        var weeklyShare: ScopedWindow.WeeklyShare? {
            guard usedPercent.isFinite else { return nil }
            return ScopedWindow.WeeklyShare(
                usedPercent: usedPercent, allowancePercent: allowancePercent.flatMap { $0.isFinite ? $0 : nil }
            )
        }
    }

    /// Decodes to `nil` instead of failing, so one odd entry does not cost the others.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    /// `{"kind": "weekly_scoped", "group": "weekly", "percent": 4, "resets_at": "…",
    /// "scope": {"model": {"display_name": "Fable"}}}`.
    private struct Limit: Decodable {
        let group: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        struct Scope: Decodable {
            let model: Model?
        }

        struct Model: Decodable {
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }

        enum CodingKeys: String, CodingKey {
            case group, percent, scope
            case resetsAt = "resets_at"
        }

        /// Only a window scoped to a model; the plan-wide ones have their own keys.
        var scopedWindow: ScopedWindow? {
            guard let name = scope?.model?.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let percent, percent.isFinite
            else { return nil }
            return ScopedWindow(
                name: name,
                isWeekly: group != "session",
                window: LimitWindow(usedPercent: percent, resetsAt: resetsAt.flatMap(ISO8601DateFormatter.parseFlexible))
            )
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
