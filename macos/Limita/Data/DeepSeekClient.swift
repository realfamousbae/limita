import Foundation

/// Fetches the DeepSeek balance with the user's API key.
///
/// `GET https://api.deepseek.com/user/balance` is DeepSeek's documented endpoint and the
/// only one an API key can read: it reports the balance per currency and whether it
/// still covers API calls. There are no rate-limit windows; spending and the forecast
/// come from Limita's own history of these readings (`BalanceLedger`).
///
/// The key is read from Limita's own Keychain item and is only ever sent to
/// api.deepseek.com. Set `LIMITA_DEEPSEEK_API` to another origin (see
/// `scripts/fake-api.py`) to test against fake responses; the key is then a dummy.
struct DeepSeekClient: Sendable {
    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// No key is stored: the service is connected but has nothing to ask with.
    struct MissingKey: LocalizedError {
        var errorDescription: String? { "Add your DeepSeek API key in Settings" }
    }

    struct RateLimited: RateLimitedError {
        let retryAfter: TimeInterval?
        var errorDescription: String? { "DeepSeek is rate-limiting balance requests" }
    }

    static let apiOverride = ProcessInfo.processInfo.environment["LIMITA_DEEPSEEK_API"].flatMap(URL.init(string:))
    private static let api = apiOverride ?? URL(string: "https://api.deepseek.com")!
    static let endpoint = api.appendingPathComponent("user/balance")

    var timeout: TimeInterval = 20
    /// Injectable so tests never touch the real Keychain.
    var apiKey: @Sendable () throws -> String? = {
        apiOverride == nil ? try KeychainStore.deepseek.read() : "fake"
    }
    /// Sends the request; injectable so tests answer without the network.
    var load: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    /// The balance with the stored key.
    func fetch(now: Date = Date()) async throws -> LiveReading {
        guard let key = try apiKey(), !key.isEmpty else { throw MissingKey() }
        return try await fetch(key: key, now: now)
    }

    /// The balance with `key`, e.g. to check a key before storing it.
    func fetch(key: String, now: Date = Date()) async throws -> LiveReading {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(request)
        } catch {
            throw FetchError(message: "Could not reach DeepSeek: \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        switch status {
        case 200:
            let balance = try Self.balance(fromResponse: data)
            return LiveReading(snapshot: LimitSnapshot(balance: balance, capturedAt: now), details: AccountDetails())
        case 401, 403:
            throw FetchError(message: "DeepSeek rejected the API key (\(status)) — check it in Settings")
        case 429:
            let header = http?.value(forHTTPHeaderField: "Retry-After")
            throw RateLimited(retryAfter: header.flatMap { ClaudeLiveClient.retryAfter($0, now: now) })
        default:
            throw FetchError(message: "DeepSeek balance API returned \(status)")
        }
    }

    /// `{"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "110.00",
    /// "granted_balance": "10.00", "topped_up_balance": "100.00"}]}`. The amounts are
    /// strings; numbers are taken too. The currency with the most money is the main one.
    static func balance(fromResponse data: Data) throws -> Balance {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FetchError(message: "DeepSeek sent a balance that is not JSON")
        }
        let isAvailable = root["is_available"] as? Bool ?? true
        let infos = (root["balance_infos"] as? [[String: Any]] ?? []).compactMap { info -> (String, Double, Double, Double)? in
            guard let currency = info["currency"] as? String, let total = amount(info["total_balance"]) else { return nil }
            return (currency, total, amount(info["granted_balance"]) ?? 0, amount(info["topped_up_balance"]) ?? 0)
        }
        guard let main = infos.enumerated().max(by: { lhs, rhs in
            // The first of equal totals wins.
            lhs.element.1 < rhs.element.1 || (lhs.element.1 == rhs.element.1 && lhs.offset > rhs.offset)
        })?.element else {
            return Balance(currency: "USD", total: 0, granted: 0, toppedUp: 0, isAvailable: isAvailable)
        }
        return Balance(
            currency: main.0, total: main.1, granted: main.2, toppedUp: main.3, isAvailable: isAvailable,
            others: infos.filter { $0.0 != main.0 }.map { Balance.Amount(currency: $0.0, total: $0.1) }
        )
    }

    private static func amount(_ value: Any?) -> Double? {
        switch value {
        case let string as String: Double(string.trimmingCharacters(in: .whitespaces))
        case let number as NSNumber: number.doubleValue
        default: nil
        }
    }
}
