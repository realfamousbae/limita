import Foundation

/// The public trackers of limit resets, one per service:
///
/// - Codex: codex-reset.com's forecast. A reset is confirmed when its `last_reset_at`
///   moves forward; `latest_alert` links the post it came from.
/// - Claude: claude-resets.com's event list (CC BY 4.0), of which only `kind: "reset"`
///   counts. Events it has not checked yet are marked provisional.
///
/// Both ask for a visible credit next to their data, a User-Agent that names the app,
/// at most one request a minute, and respect for `Retry-After`. Parsing is lenient:
/// a missing or unknown field drops that event, never the whole feed.
///
/// Set `LIMITA_RESET_FEED_CODEX` / `LIMITA_RESET_FEED_CLAUDE` to another URL (a
/// `file://` one works) with the same JSON to test against a local copy.
enum ResetFeed {
    static let codexURL = URL(string: "https://codex-reset.com/api/forecast")!
    static let claudeURL = URL(string: "https://claude-resets.com/api/resets")!

    static func url(for service: Service, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        switch service {
        case .codex: environment["LIMITA_RESET_FEED_CODEX"].flatMap(URL.init(string:)) ?? codexURL
        case .claude: environment["LIMITA_RESET_FEED_CLAUDE"].flatMap(URL.init(string:)) ?? claudeURL
        }
    }

    /// "Limita/0.18.0 (+https://github.com/realfamousbae/limita)".
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return "Limita/\(version.isEmpty ? "dev" : version) (+https://github.com/realfamousbae/limita)"
    }()

    struct FeedError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A 429. `retryAfter` is the wait the server asked for, when it named one.
    struct RateLimited: LocalizedError {
        let retryAfter: TimeInterval?
        var errorDescription: String? { "The reset tracker is rate-limiting requests" }
    }

    /// The service's latest events, newest first.
    static func fetch(_ service: Service, from url: URL, now: Date = Date()) async throws -> [ResetEvent] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        // `file://` answers are not HTTP; they count as 200.
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if status == 429 {
            let header = http?.value(forHTTPHeaderField: "Retry-After")
            throw RateLimited(retryAfter: header.flatMap { ClaudeLiveClient.retryAfter($0, now: now) })
        }
        guard (200..<300).contains(status) else { throw FeedError(message: "\(url.host ?? "The tracker") answered \(status)") }
        return try parse(data, for: service)
    }

    /// Lenient about fields, but a body that is not a JSON object (e.g. an error page
    /// served with 200) is a failure: taken as "no events", it would hide the line and,
    /// on a first run, record nothing, so the next good answer would announce old resets.
    static func parse(_ data: Data, for service: Service) throws -> [ResetEvent] {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw FeedError(message: "The reset tracker sent something other than JSON")
        }
        switch service {
        case .codex: return codexForecast(from: data).map { [$0] } ?? []
        case .claude: return claudeResets(from: data)
        }
    }

    // MARK: - Parsing

    /// The last confirmed Codex reset, `nil` when the forecast names none.
    static func codexForecast(from data: Data) -> ResetEvent? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["last_reset_at"] as? String,
              let date = ISO8601DateFormatter.parseFlexible(raw)
        else { return nil }
        // The alert is about this reset only if it is a reset at the same moment.
        var url: URL?
        if let alert = root["latest_alert"] as? [String: Any],
           alert["kind"] as? String == "reset",
           let link = (alert["confirmation_url"] as? String) ?? (alert["url"] as? String) {
            let times = ["source_at", "observed_at", "confirmed_at"].compactMap {
                (alert[$0] as? String).flatMap(ISO8601DateFormatter.parseFlexible)
            }
            if times.contains(where: { abs($0.timeIntervalSince(date)) < 60 }) {
                url = URL(string: link)
            }
        }
        return ResetEvent(
            id: "codex-reset-\(Int(date.timeIntervalSince1970))",
            service: .codex, kind: .global, date: date,
            url: url ?? ResetEvent.Source.codexReset.site,
            source: .codexReset
        )
    }

    /// Claude's resets, newest first; policy changes and malformed events are dropped.
    static func claudeResets(from data: Data) -> [ResetEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let claude = providers["claude"] as? [String: Any],
              let events = claude["events"] as? [[String: Any]]
        else { return [] }
        let meta = root["meta"] as? [String: Any]
        let provisionalIDs = Set(meta?["provisionalEventIds"] as? [String] ?? [])
        let parsed = events.compactMap { event -> ResetEvent? in
            guard event["kind"] as? String == "reset",
                  let id = event["id"] as? String ?? (event["id"] as? NSNumber)?.stringValue,
                  let date = (event["date"] as? String).flatMap(ISO8601DateFormatter.parseFlexible)
            else { return nil }
            let kind: ResetEvent.Kind = event["resetType"] as? String == "banked"
                ? .banked(usableUntil: (event["usableUntil"] as? String).flatMap(ISO8601DateFormatter.parseFlexible))
                : .global
            let verification = event["verification"] as? String
            return ResetEvent(
                id: "claude-\(id)", service: .claude, kind: kind, date: date,
                url: (event["url"] as? String).flatMap(URL.init(string:)) ?? ResetEvent.Source.claudeResets.site,
                scope: event["scope"] as? String,
                note: event["note"] as? String,
                source: .claudeResets,
                isProvisional: provisionalIDs.contains(id) || (verification != nil && verification != "curated")
            )
        }
        return parsed.sorted { $0.date > $1.date }
    }
}
