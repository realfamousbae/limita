import Foundation
import CoreFoundation

struct ProviderData: Sendable, Equatable {
    struct Quota: Sendable, Equatable {
        let name: String
        let shortName: String
        let window: LimitWindow
    }

    var quotas: [Quota] = []
    var metrics: [String: String] = [:]
    var totalCredits: Double?
    var history: SpendHistory?
    var notice: String?
}

struct SpendHistory: Codable, Sendable, Equatable {
    let currency: String
    var days: [DayKey: [String: Double]]
    var estimated = false
    var accountScope: String?

    var hasModelBreakdown: Bool {
        days.values.contains { $0.keys.contains { !$0.isEmpty } }
    }

    struct Summary {
        let today: Double?
        let yesterday: Double?
        let month: Double?
        let monthComplete: Bool
        let dailyAverage: Double?
        let weekComplete: Bool
        let topModel: String?
    }

    func summary(at now: Date, for service: Service) -> Summary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: service == .qwenAPI ? 8 * 3600 : 0)!
        let formatter = DayKeys.formatter(timeZone: calendar.timeZone)
        let today = calendar.startOfDay(for: now)
        let dayKey = formatter.string(from: today)
        let monthStart = calendar.dateInterval(of: .month, for: today)!.start
        let monthKey = formatter.string(from: monthStart)
        let monthDays = calendar.dateComponents([.day], from: monthStart, to: today).day ?? 0
        let priorMonthDates = (0..<monthDays).map { formatter.string(from: calendar.date(byAdding: .day, value: $0, to: monthStart)!) }
        let month = days.filter { $0.key >= monthKey && $0.key <= dayKey }.values
        let weekKeys = (1...7).map { formatter.string(from: calendar.date(byAdding: .day, value: -$0, to: today)!) }
        let week = weekKeys.compactMap { days[$0] }
        let sum: ([String: Double]) -> Double = { $0.values.reduce(0, +) }
        var models: [String: Double] = [:]
        for amounts in week {
            for (model, amount) in amounts where !model.isEmpty && model != "Other" {
                models[model, default: 0] += amount
            }
        }
        let top = models.filter { $0.value > 0 }.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.first?.key
        return Summary(today: days[dayKey].map(sum), yesterday: days[weekKeys[0]].map(sum),
                       month: month.isEmpty ? nil : month.map(sum).reduce(0, +),
                       monthComplete: priorMonthDates.allSatisfy { days[$0] != nil },
                       dailyAverage: week.isEmpty ? nil : week.map(sum).reduce(0, +) / Double(week.count),
                       weekComplete: week.count == 7, topModel: top)
    }

    static func amount(_ value: Double, currency: String) -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(value != 0 && abs(value) < 0.01 ? 2...6 : 2...2)))
    }

    static func file(for service: Service) -> URL {
        let prefix = ProviderClient.isDemo ? "demo-" : ""
        return BalanceLedger.defaultURL.deletingLastPathComponent().appendingPathComponent("\(prefix)\(service.rawValue)-spend.json")
    }

    static func load(_ service: Service) -> Self? {
        guard let data = try? Data(contentsOf: file(for: service)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func merge(into service: Service) {
        var merged = Self.load(service).flatMap { $0.currency == currency && $0.accountScope == accountScope ? $0 : nil } ?? self
        merged.days.merge(days) { _, new in new }
        merged.days = Dictionary(uniqueKeysWithValues: merged.days.sorted { $0.key > $1.key }.prefix(370).map { ($0.key, $0.value) })
        let url = Self.file(for: service)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(merged).write(to: url, options: .atomic)
        } catch {
            // The current reading remains available in memory.
        }
    }
}

extension Service {
    var providerUsesCLI: Bool {
        self == .qwenCoding || self == .qwenToken || self == .qwenAPI
    }

    var providerLink: URL {
        let address: String
        switch self {
        case .zaiCoding: address = "https://z.ai/manage-apikey/apikey-list"
        case .zaiAPI: address = "https://z.ai/manage-apikey/billing"
        case .qwenCoding, .qwenToken: address = "https://docs.modelstudio.console.alibabacloud.com/en/model-studio/cli/installation"
        case .qwenAPI: address = "https://api.alibabacloud.com/api-tools/cli/ModelStudio/2026-02-10"
        case .openCodeGo, .openCodeAPI: address = "https://opencode.ai/console"
        case .openRouter: address = "https://openrouter.ai/settings/keys"
        default: preconditionFailure("No provider setup page")
        }
        return URL(string: address)!
    }

    var providerSetup: String {
        switch self {
        case .qwenCoding, .qwenToken: "Install Bailian CLI and sign in with bl auth login --console --console-site international."
        case .qwenAPI: "Configure a read-only Alibaba Cloud CLI profile for Model Studio and Expenses and Costs."
        case .zaiAPI: "Sign in to Z.ai to read account balance and billing history."
        case .openCodeAPI: "Enter a Console key with Usage read permission and the workspace ID."
        case .openRouter: "Use a Management key for account balance and model history, or an API key for its own usage."
        default: "Enter the provider API key."
        }
    }
}

enum ProviderClient {
    static let isDemo = ProcessInfo.processInfo.environment["LIMITA_FAKE_PROVIDERS"] == "1"
    private static let demoOrigin = "http://127.0.0.1:8377"

    private static func requestURL(_ address: String) -> URL {
        guard isDemo, var parts = URLComponents(string: address), let host = parts.host else { return URL(string: address)! }
        let fixture: String
        switch host {
        case "api.z.ai": fixture = "zai"
        case "opencode.ai": fixture = "opencode"
        case "openrouter.ai": fixture = "openrouter"
        case "modelstudio.invalid": fixture = "qwen"
        default: preconditionFailure("Unknown demo provider")
        }
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = 8377
        parts.path = "/providers/\(fixture)" + parts.path
        return parts.url!
    }

    struct Credentials: Codable, Sendable, Equatable {
        var key = ""
        var workspace = ""
        var refreshToken: String?
        var expiresAt: Date?
        var organization: String?
        var project: String?
    }

    struct Failure: LocalizedError {
        let text: String
        var status: Int? = nil
        var errorDescription: String? { text }
    }

    struct Throttled: RateLimitedError {
        let retryAfter: TimeInterval?
        var errorDescription: String? { "Provider is rate-limiting usage requests" }
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil)

    static func keychain(_ service: Service) -> KeychainStore {
        KeychainStore(service: "com.limita.\(isDemo ? "fake" : "app").\(service.rawValue)")
    }

    static func credentials(_ service: Service) throws -> Credentials {
        guard let secret = try keychain(service).read(), let bytes = secret.data(using: .utf8) else {
            throw Failure(text: "Connect \(service.displayName) in Settings")
        }
        return try JSONDecoder().decode(Credentials.self, from: bytes)
    }

    static func fetch(_ service: Service, supplied: Credentials? = nil, now: Date = .now) async throws -> LiveReading {
        let credentials: Credentials
        if let supplied { credentials = supplied }
        else {
            let stored = try self.credentials(service)
            credentials = service == .openCodeAPI ? try await renewedOpenCode(stored, now: now) : stored
        }
        if isDemo && !["", "demo", "demo-management", "demo-bad", "demo-limited", "demo-partial", "demo-session"].contains(credentials.key) {
            throw Failure(text: "Use a demo credential in fake API mode.")
        }
        var provider = ProviderData()
        var balance: Balance?
        switch service {
        case .zaiCoding:
            let root = try await json("https://api.z.ai/api/monitor/usage/quota/limit", authorization: credentials.key)
            provider.quotas = zaiQuotas(root)
        case .openCodeGo:
            let root = try await json("https://opencode.ai/inference/go/v1/usage", authorization: "Bearer " + credentials.key)
            let usage = root["usage"] as? JSON ?? [:]
            provider.quotas = [
                quota("5 HOURS", "5h", usage["rolling"] as? JSON, percent: "percent", reset: "resetsAt"),
                quota("7 DAYS", "7d", usage["weekly"] as? JSON, percent: "percent", reset: "resetsAt"),
                quota("MONTH", "1m", usage["monthly"] as? JSON, percent: "percent", reset: "resetsAt"),
            ].compactMap { $0 }
        case .qwenCoding, .qwenToken:
            let command = service == .qwenCoding ? "coding-plan" : "token-plan"
            let root = try await qwenCommand(["bl", "bailian"], args: ["usage", command, "--output", "json"], failure: service.providerSetup)
            provider.quotas = qwenQuotas(root, coding: service == .qwenCoding)
        case .qwenAPI:
            let billing = try await qwenBilling(profile: credentials.workspace, now: now)
            balance = billing.0
            provider = billing.1
        case .openRouter:
            let result = try await openRouter(credentials.key, now: now)
            balance = result.0
            provider = result.1
        case .openCodeAPI:
            let result = try await openCode(credentials)
            balance = result.0
            provider = result.1
        case .zaiAPI:
            (balance, provider) = try await zaiBilling(credentials, now: now)
        default:
            throw Failure(text: "Unsupported provider connection")
        }
        guard !provider.quotas.isEmpty || !provider.metrics.isEmpty || provider.history != nil || balance != nil else {
            throw Failure(text: provider.notice ?? "No usage data for this plan. Check the provider account and permissions.")
        }
        let headline = provider.quotas.first
        let snapshot = LimitSnapshot(fiveHour: headline?.shortName == "5h" ? headline?.window : nil,
                                     sevenDay: headline?.shortName == "5h" ? nil : headline?.window,
                                     capturedAt: now, hasNoFiveHourLimit: headline != nil && headline?.shortName != "5h",
                                     longWindowDays: headline?.shortName == "1m" ? 30 : nil, balance: balance)
        return LiveReading(snapshot: snapshot, details: AccountDetails(provider: provider))
    }

    private static let openCodeAuth = "https://opencode.ai/console/auth/device/"
    private static let openCodeClient = "opencode-cli"

    struct OpenCodeDevice: Decodable, Sendable {
        let device_code: String
        let user_code: String
        let verification_uri_complete: String
        let expires_in: TimeInterval
        let interval: TimeInterval

        var verificationURL: URL? {
            if ProviderClient.isDemo && verification_uri_complete == "/demo-opencode" { return URL(string: ProviderClient.demoOrigin + verification_uri_complete) }
            guard let url = URL(string: verification_uri_complete, relativeTo: URL(string: "https://opencode.ai/console/"))?.absoluteURL,
                  url.scheme == "https", url.host == "opencode.ai", url.user == nil, url.password == nil else { return nil }
            return url
        }
    }

    static func beginOpenCodeSignIn() async throws -> OpenCodeDevice {
        let bytes = try await authRequest("code", ["client_id": openCodeClient, "supports_org_scope": true])
        let device = try JSONDecoder().decode(OpenCodeDevice.self, from: bytes)
        guard device.verificationURL != nil else { throw Failure(text: "Invalid OpenCode sign-in URL") }
        return device
    }

    static func finishOpenCodeSignIn(_ device: OpenCodeDevice) async throws -> Credentials {
        var interval = min(max(device.interval, 1), 30)
        let deadline = Date().addingTimeInterval(min(max(device.expires_in, 0), 900))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let body = try decode(try await authRequest("token", [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": device.device_code, "client_id": openCodeClient,
            ]))
            switch body["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case nil: return try openCodeToken(body)
            default: throw Failure(text: "OpenCode sign-in ended. Try again in Settings.")
            }
        }
        throw Failure(text: "OpenCode sign-in code expired. Try again.")
    }

    private static func openCodeToken(_ body: JSON, workspace: String? = nil) throws -> Credentials {
        guard let token = body["access_token"] as? String, !token.isEmpty,
              let refresh = body["refresh_token"] as? String, !refresh.isEmpty,
              let expires = number(body["expires_in"]), expires > 0,
              let scope = (body["org_id"] as? String) ?? workspace, !scope.isEmpty else {
            throw Failure(text: "OpenCode did not return a workspace session. Select a workspace when you sign in.")
        }
        return Credentials(key: token, workspace: scope, refreshToken: refresh,
                           expiresAt: Date().addingTimeInterval(expires))
    }

    private static func renewedOpenCode(_ stored: Credentials, now: Date) async throws -> Credentials {
        guard let refresh = stored.refreshToken, let expires = stored.expiresAt, expires.timeIntervalSince(now) < 60 else { return stored }
        let body = try decode(try await authRequest("token", [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": openCodeClient,
        ]))
        let renewed = try openCodeToken(body, workspace: stored.workspace)
        guard renewed.workspace == stored.workspace else { throw Failure(text: "OpenCode workspace changed. Reconnect in Settings.") }
        try replaceOpenCodeSession(stored, with: renewed)
        return renewed
    }

    static let credentialsLock = NSLock()

    private static func replaceOpenCodeSession(_ stored: Credentials, with renewed: Credentials) throws {
        try credentialsLock.withLock {
            guard try credentials(.openCodeAPI) == stored else { throw Failure(text: "OpenCode connection changed") }
            let bytes = try JSONEncoder().encode(renewed)
            try keychain(.openCodeAPI).save(String(decoding: bytes, as: UTF8.self))
        }
    }

    private static func authRequest(_ operation: String, _ parameters: JSON) async throws -> Data {
        var request = URLRequest(url: requestURL(openCodeAuth + operation))
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse else { throw Failure(text: "Invalid OpenCode sign-in response") }
        if response.statusCode == 429 {
            throw Throttled(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        guard response.statusCode == 200 || operation == "token" && response.statusCode == 400 else {
            throw Failure(text: "OpenCode sign-in returned HTTP \(response.statusCode)")
        }
        return data
    }

    typealias JSON = [String: Any]

    static func number(_ value: Any?) -> Double? {
        if let integer = value as? NSNumber, CFGetTypeID(integer) == CFBooleanGetTypeID() { return nil }
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value), number > 0 {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        return (value as? String).flatMap(ISO8601DateFormatter.parseFlexible)
    }

    private static func quota(_ label: String, _ short: String, _ data: JSON?, percent: String, reset: String,
                              scale: Double = 1) -> ProviderData.Quota? {
        guard let data, let used = number(data[percent]), used >= 0 else { return nil }
        return .init(name: label, shortName: short, window: .init(usedPercent: used * scale, resetsAt: date(data[reset])))
    }

    static func qwenQuotas(_ root: JSON, coding: Bool) -> [ProviderData.Quota] {
        if coding {
            return [("per5Hour", "5 HOURS", "5h"), ("perWeek", "7 DAYS", "7d"), ("perBillMonth", "BILLING MONTH", "1m")]
                .compactMap { key, label, short in
                    quota(label, short, root[key] as? JSON, percent: "percentage", reset: "resetTime", scale: 100)
                }
        }
        return root.keys.sorted().compactMap { key in
            guard key.hasPrefix("per"), key.hasSuffix("Percentage") else { return nil }
            let window = String(key.dropLast("Percentage".count))
            let label = window == "perBillMonth" || window == "per1Month" ? "MONTH" : String(window.dropFirst(3)).uppercased()
            return quota(label, label == "MONTH" ? "1m" : label.lowercased(), root,
                         percent: key, reset: window + "ResetTime", scale: 100)
        }
    }

    static func zaiQuotas(_ root: JSON) -> [ProviderData.Quota] {
        let data = root["data"] as? JSON ?? [:]
        let limits = data["limits"] as? [JSON] ?? []
        return limits.compactMap { item in
            let duration = number(item["number"])
            let label: (String, String)
            switch (item["type"] as? String, duration, number(item["unit"])) {
            case ("TIME_LIMIT", _, _): label = ("MONTHLY TOOLS", "1m")
            case ("TOKENS_LIMIT", 5, _): label = ("5 HOURS", "5h")
            case ("TOKENS_LIMIT", 7, _), ("TOKENS_LIMIT", _, 6): label = ("7 DAYS", "7d")
            case ("TOKENS_LIMIT", _, _): label = ("MODEL QUOTA", "quota")
            default: return nil
            }
            return quota(label.0, label.1, item, percent: "percentage", reset: "nextResetTime")
        }
        .sorted { lhs, rhs in
            let order = ["5h": 0, "7d": 1, "quota": 2, "1m": 3]
            return order[lhs.shortName, default: 4] < order[rhs.shortName, default: 4]
        }
    }

    // The Z.ai console uses this session for account billing. Read only from the
    // separate sign-in window and only after the user confirms the connection.
    static let zaiSessionScript = """
    (() => {
      if (location.origin !== 'https://z.ai') return null;
      const user = JSON.parse(localStorage.getItem('platform-user-info') || '{}');
      return {
        key: localStorage.getItem('z-ai-open-platform-token-production') || '',
        workspace: String(user.customerNumber || ''),
        organization: localStorage.getItem('Bigmodel-Organization'),
        project: localStorage.getItem('Bigmodel-Project')
      };
    })()
    """

    private static func zaiBilling(_ credentials: Credentials, now: Date) async throws -> (Balance?, ProviderData) {
        guard !credentials.workspace.isEmpty, !credentials.key.isEmpty else {
            throw Failure(text: "Sign in to Z.ai and open its billing page before connecting.")
        }
        let base = "https://api.z.ai/api/platform-charge-zai"
        let auth = "Bearer " + credentials.key
        let headers = ["Bigmodel-Organization": credentials.organization, "Bigmodel-Project": credentials.project,
                       "Refer": "https://z.ai/manage-apikey/billing"].compactMapValues { $0 }
        var balance: Balance?
        var provider = ProviderData()
        do {
            let bytes = try await get(base + "/business/accountBalance", authorization: auth, headers: headers,
                                      body: ["customerId": credentials.workspace])
            let report = try zaiData(decode(bytes))
            if let amount = number(report["totalBalance"]) { balance = simpleBalance(amount, "USD") }
        } catch let error as Throttled { throw error }
        catch { provider.notice = "Z.ai balance unavailable. Reconnect if your session has expired." }

        let months = Calendar(identifier: .gregorian)
        let formatter = DayKeys.formatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        var history = SpendHistory(currency: "USD", days: [:])
        do {
            for offset in 0...1 {
                guard let date = months.date(byAdding: .month, value: -offset, to: now) else { continue }
                let period = String(formatter.string(from: date).prefix(7))
                var month: [DayKey: [String: Double]] = [:]
                var complete = false
                for page in 1...25 {
                    var address = URLComponents(string: base + "/bill/day")!
                    address.queryItems = [URLQueryItem(name: "customerId", value: credentials.workspace),
                                          .init(name: "billingPeriod", value: period),
                                          .init(name: "pageNum", value: String(page)), .init(name: "pageSize", value: "100")]
                    let report = try zaiData(decode(try await get(address.string!, authorization: auth, headers: headers)))
                    guard let rows = report["records"] as? [JSON] else { throw Failure(text: "Z.ai billing history is unavailable") }
                    for row in rows {
                        guard let rawDate = row["billingDate"] as? String, let cost = number(row["settlementAmount"]) else { continue }
                        let day = String(rawDate.prefix(10))
                        guard day.hasPrefix(period), formatter.date(from: day) != nil else { continue }
                        let model = row["modelCode"] as? String ?? "Other"
                        month[day, default: [:]][model.isEmpty ? "Other" : model, default: 0] += cost
                    }
                    if rows.count < 100 || number(report["total"]).map({ Double(page * 100) >= $0 }) == true {
                        complete = true
                        break
                    }
                }
                if complete { history.days.merge(month) { _, new in new } }
            }
            provider.history = history
        } catch let error as Throttled { throw error }
        catch {
            if !history.days.isEmpty { provider.history = history }
            provider.notice = "Some Z.ai billing history is unavailable. Open billing or reconnect in Settings."
        }
        return (balance, provider)
    }

    private static func zaiData(_ root: JSON) throws -> JSON {
        guard let code = number(root["code"]), code == 0 || code == 200, let data = root["data"] as? JSON else {
            throw Failure(text: "Z.ai billing rejected the session. Sign in again in Settings.")
        }
        return data
    }

    private static func get(_ address: String, authorization: String, workspace: String = "", headers: [String: String] = [:],
                            body: JSON? = nil) async throws -> Data {
        var request = URLRequest(url: requestURL(address))
        request.timeoutInterval = 15
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if !workspace.isEmpty { request.setValue(workspace, forHTTPHeaderField: "x-org-id") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw Failure(text: "Invalid provider response") }
        switch response.statusCode {
        case 200: return data
        case 401, 403: throw Failure(text: "The provider denied access (\(response.statusCode)). Check the key and its permissions.", status: response.statusCode)
        case 429: throw Throttled(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        default: throw Failure(text: "Provider usage request returned HTTP \(response.statusCode)")
        }
    }

    private static func json(_ url: String, authorization: String, workspace: String = "") async throws -> JSON {
        try decode(try await get(url, authorization: authorization, workspace: workspace))
    }

    private static func decode(_ bytes: Data) throws -> JSON {
        guard let output = try? JSONSerialization.jsonObject(with: bytes) as? JSON else {
            throw Failure(text: "Provider returned an unreadable usage response")
        }
        return output
    }

    private static func simpleBalance(_ total: Double, _ currency: String) -> Balance {
        Balance(currency: currency, total: total, granted: 0, toppedUp: 0, isAvailable: true)
    }

    private static func openRouter(_ key: String, now: Date) async throws -> (Balance?, ProviderData) {
        let auth = "Bearer " + key
        let base = "https://openrouter.ai/api/v1"
        let info: JSON
        do {
            let keyResponse = try await json(base + "/key", authorization: auth)
            info = keyResponse["data"] as? JSON ?? [:]
        } catch let failure as Failure where failure.status == 403 {
            info = [:]
        }
        var output = ProviderData()
        var balance: Balance?
        let management = info["is_management_key"] as? Bool
        if management != false {
            do {
                let root = try await json(base + "/credits", authorization: auth)
                if let credits = root["data"] as? JSON, let purchased = number(credits["total_credits"]),
                   let used = number(credits["total_usage"]) {
                    balance = simpleBalance(purchased - used, "USD")
                    if purchased > 0 { output.totalCredits = purchased }
                }
            } catch let error as Throttled { throw error }
            catch { output.notice = "Account balance unavailable with this key." }
            do {
                let result = try await json(base + "/activity", authorization: auth)
                guard let rows = result["data"] as? [JSON] else { throw Failure(text: "Activity response is missing daily data") }
                let formatter = DayKeys.formatter(timeZone: TimeZone(secondsFromGMT: 0)!)
                var days: [DayKey: [String: Double]] = [:]
                for offset in 1...30 {
                    days[formatter.string(from: now.addingTimeInterval(-Double(offset) * 86_400))] = [:]
                }
                for row in rows {
                    guard let day = (row["date"] as? String).map({ String($0.prefix(10)) }),
                          days[day] != nil, let cost = number(row["usage"]) else { continue }
                    days[day, default: [:]][row["model"] as? String ?? "Other", default: 0] += cost
                }
                output.history = SpendHistory(currency: "USD", days: days)
            } catch let error as Throttled { throw error }
            catch { output.notice = "Model history unavailable. Use a Management key with activity access." }
        }
        if output.history == nil {
            for (field, title) in [("usage_daily", "KEY SPEND TODAY"), ("usage_weekly", "KEY SPEND THIS WEEK"),
                                   ("usage_monthly", "KEY SPEND THIS MONTH"), ("limit_remaining", "KEY LIMIT LEFT")] {
                if let amount = number(info[field]) { output.metrics[title] = SpendHistory.amount(amount, currency: "USD") }
            }
            if let daily = number(info["usage_daily"]) {
                let formatter = DayKeys.formatter(timeZone: TimeZone(secondsFromGMT: 0)!)
                output.history = SpendHistory(currency: "USD", days: [formatter.string(from: now): ["": daily]])
            }
            output.notice = "Use a Management key to view model history and account credits."
        }
        return (balance, output)
    }

    private static func openCode(_ credentials: Credentials) async throws -> (Balance?, ProviderData) {
        guard credentials.workspace.range(of: "^(org|wrk)_[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw Failure(text: "Enter the OpenCode workspace ID (org_… or wrk_…).")
        }
        let base = "https://opencode.ai/console/api"
        let auth = "Bearer " + credentials.key
        var balance: Balance?
        var provider = ProviderData()
        do {
            let root = try await json(base + "/billing/status", authorization: auth, workspace: credentials.workspace)
            if let amount = number(root["availableMicroCents"]) { balance = simpleBalance(amount / 100_000_000, "USD") }
        } catch let error as Throttled { throw error }
        catch { provider.notice = "Balance requires a Console key with Billing read access or a signed-in workspace owner." }
        do {
            let bytes = try await get(base + "/v2/usage/export?range=90d", authorization: auth, workspace: credentials.workspace)
            provider.history = try openCodeHistory(String(decoding: bytes, as: UTF8.self))
        } catch let error as Throttled { throw error }
        catch {
            provider.notice = [provider.notice, "History requires Usage read access in this workspace."].compactMap { $0 }.joined(separator: " ")
        }
        return (balance, provider)
    }

    static func openCodeHistory(_ csv: String) throws -> SpendHistory {
        let table = parseCSV(String(csv.trimmingPrefix("\u{feff}")))
        guard let header = table.first,
              let day = header.firstIndex(of: "day"), let model = header.firstIndex(of: "model"),
              let cost = header.firstIndex(of: "cost_micro_cents") else {
            throw Failure(text: "OpenCode returned an unrecognized usage export")
        }
        let providerIndex = header.firstIndex(of: "provider")
        var days: [DayKey: [String: Double]] = [:]
        for row in table.dropFirst() where row.count == header.count {
            if let providerIndex, !["opencode", "opencode-go", "zen"].contains(row[providerIndex]) { continue }
            guard row[day].range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil,
                  let charge = number(row[cost]) else { continue }
            days[row[day], default: [:]][row[model].isEmpty ? "Other" : row[model], default: 0] += charge / 100_000_000
        }
        return SpendHistory(currency: "USD", days: days)
    }

    private static func parseCSV(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var characters = csv.unicodeScalars.makeIterator()
        var next = characters.next()
        while let char = next {
            next = characters.next()
            switch char {
            case "\"":
                if quoted && next == "\"" { field.append("\""); next = characters.next() }
                else { quoted.toggle() }
            case "," where !quoted: row.append(field); field = ""
            case "\n" where !quoted: row.append(field); rows.append(row); row = []; field = ""
            case "\r" where !quoted: break
            default: field.unicodeScalars.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func qwenBilling(profile: String, now: Date) async throws -> (Balance?, ProviderData) {
        let formatter = DayKeys.formatter(timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        let start = formatter.string(from: now.addingTimeInterval(-34 * 86_400))
        let end = formatter.string(from: now)
        let profileArgs = profile.isEmpty ? [] : ["--profile", profile]
        let identity = try await qwenCommand(["aliyun"], args: ["sts", "get-caller-identity"] + profileArgs,
                               failure: "Check the Alibaba Cloud CLI profile and its STS read permission.")
        guard let account = identity["AccountId"] as? String, !account.isEmpty else {
            throw Failure(text: "Alibaba Cloud did not identify the billing account.")
        }
        var provider = ProviderData()
        var balance: Balance?
        do {
            let report = try await qwenCommand(["aliyun"], args: ["modelstudio", "get-billing-trend",
                "--granularity", "DAY", "--time-period", "{\"start\":\"\(start)\",\"end\":\"\(end)\"}",
                "--group-by", "[{\"code\":\"BASE_MODEL\"}]",
                "--filter", "{\"dimensions\":[{\"code\":\"CHARGE_TYPE\",\"values\":[\"postpaid\"],\"selectType\":\"INCLUDE\"}]}",
                "--region", "ap-southeast-1"] + profileArgs, failure: Service.qwenAPI.providerSetup)
            provider.history = qwenHistory(report)
            provider.history?.accountScope = account
        } catch { provider.notice = "Model Studio billing history unavailable. Check the CLI version and profile permissions." }
        do {
            let report = try await qwenCommand(["aliyun"], args: ["bssopenapi", "query-account-balance"] + profileArgs, failure: Service.qwenAPI.providerSetup)
            if let data = report["Data"] as? JSON, let amount = number(data["AvailableAmount"]), let currency = data["Currency"] as? String {
                balance = simpleBalance(amount, currency)
            }
        } catch {
            provider.notice = [provider.notice, "Alibaba Cloud account balance unavailable."].compactMap { $0 }.joined(separator: " ")
        }
        return (balance, provider)
    }

    static func qwenHistory(_ root: JSON) -> SpendHistory? {
        let data = root["data"] as? JSON ?? root
        guard let periods = data["resultByTime"] as? [JSON] else { return nil }
        let currency = (data["costTotals"] as? JSON)?["currency"] as? String
            ?? periods.lazy.compactMap { ($0["total"] as? JSON)?["currency"] as? String }.first
        guard let currency else { return nil }
        var days: [DayKey: [String: Double]] = [:]
        for period in periods {
            guard let date = period["period"] as? String, date.count == 8, date.allSatisfy(\.isNumber) else { continue }
            let day = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
            var attributed = 0.0
            for row in period["periodDetails"] as? [JSON] ?? [] {
                guard let charge = number(row["amount"]) else { continue }
                let model = row["name"] as? String ?? row["key"] as? String ?? "Other"
                days[day, default: [:]][model, default: 0] += charge
                attributed += charge
            }
            if let total = number((period["total"] as? JSON)?["amount"]), abs(total - attributed) > 1e-8 || days[day] == nil {
                days[day, default: [:]]["Other", default: 0] += total - attributed
            }
        }
        return SpendHistory(currency: currency, days: days)
    }

    private static func qwenCommand(_ names: [String], args: [String], failure: String) async throws -> JSON {
        if isDemo { return try await json("https://modelstudio.invalid/" + args[1], authorization: "demo") }
        return try cli(names, args: args, failure: failure)
    }

    private static func cli(_ names: [String], args: [String], failure: String) throws -> JSON {
        guard let executable = names.lazy.compactMap(CLILocator.find).first else { throw Failure(text: failure) }
        let process = Process()
        process.executableURL = executable
        process.environment = CLILocator.environment
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { throw Failure(text: failure) }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(text: failure) }
        return try decode(bytes)
    }
}
