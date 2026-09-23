import Foundation

/// Reads Codex rate limits from the Codex CLI's own session logs.
///
/// Codex writes a rollout JSONL per session under
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO8601>-<uuid>.jsonl`, appending a
/// `token_count` event after every assistant response. Those events carry the live
/// rate limits:
///
/// ```json
/// {"type":"event_msg","payload":{"type":"token_count","rate_limits":{
///   "primary":  {"used_percent":96.0,"window_minutes":300,"resets_at":1789751544},
///   "secondary":{"used_percent":55.0,"window_minutes":10080,"resets_at":1790268541}}}}
/// ```
///
/// We take the newest session file and scan it backwards for the last such event.
/// Windows are classified by `window_minutes` rather than by the `primary`/`secondary`
/// key, since those names describe ordering, not duration.
struct CodexLimitsReader: Sendable {
    /// How old a snapshot may be before the UI marks it stale.
    static let staleAfter: TimeInterval = 30 * 60

    private let sessionsDirectory: URL
    private let archivedSessionsDirectory: URL

    init(sessionsDirectory: URL? = nil, archivedSessionsDirectory: URL? = nil) {
        let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        self.sessionsDirectory = sessionsDirectory
            ?? codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        self.archivedSessionsDirectory = archivedSessionsDirectory
            ?? codexDirectory.appendingPathComponent("archived_sessions", isDirectory: true)
    }

    // MARK: - Reading

    /// Never throws: every failure is a `.unavailable` state with a reason for the user.
    func read(now: Date = Date()) -> ServiceState {
        let files = sessionFilesNewestFirst()
        guard !files.isEmpty else {
            return .unavailable(reason: "Codex CLI не найден или ещё не создал файлы сессий")
        }

        var match: (URL, RateLimitsPayload)?
        for file in files {
            if let payload = Self.lastRateLimits(in: file) {
                match = (file, payload)
                break
            }
        }
        guard let (file, payload) = match else {
            return .unavailable(reason: "В сессиях Codex ещё нет данных о лимитах")
        }

        let snapshot = Self.snapshot(from: payload, capturedAt: modificationDate(of: file) ?? now)
        guard !snapshot.isEmpty else {
            return .unavailable(reason: "Codex вернул лимиты в незнакомом формате")
        }
        return .from(snapshot, staleAfter: Self.staleAfter, now: now)
    }

    // MARK: - Locating the newest session

    private func sessionFilesNewestFirst() -> [URL] {
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator where isRollout(file) {
                files.append(file)
            }
        }

        let archived = (try? FileManager.default.contentsOfDirectory(
            at: archivedSessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        files.append(contentsOf: archived.filter(isRollout))

        return files.sorted {
            (modificationDate(of: $0) ?? .distantPast) > (modificationDate(of: $1) ?? .distantPast)
        }
    }

    private func isRollout(_ file: URL) -> Bool {
        file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl"
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Parsing

    /// Scans `file` from the end and returns the first `rate_limits` object found.
    ///
    /// Rate limits are appended throughout the session, so the last one is the current
    /// one and reading the tail avoids parsing megabytes of transcript.
    static func lastRateLimits(in file: URL) -> RateLimitsPayload? {
        for line in TailLineReader(url: file) {
            guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
            // One malformed line must not abort the scan — transcripts can be truncated
            // mid-write if the CLI was killed.
            guard let record = try? JSONDecoder().decode(RolloutRecord.self, from: data),
                  let limits = record.payload?.rateLimits
            else { continue }
            return limits
        }
        return nil
    }

    static func snapshot(from payload: RateLimitsPayload, capturedAt: Date) -> LimitSnapshot {
        var fiveHour: LimitWindow?
        var sevenDay: LimitWindow?

        for entry in [payload.primary, payload.secondary].compactMap({ $0 }) {
            guard let window = entry.limitWindow else { continue }
            switch entry.scale {
            case .fiveHour: fiveHour = fiveHour ?? window
            case .sevenDay: sevenDay = sevenDay ?? window
            case .unknown: continue
            }
        }

        return LimitSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, capturedAt: capturedAt)
    }

    // MARK: - Wire format

    struct RolloutRecord: Decodable {
        let payload: Payload?

        struct Payload: Decodable {
            let rateLimits: RateLimitsPayload?

            enum CodingKeys: String, CodingKey {
                case rateLimits = "rate_limits"
            }
        }
    }

    struct RateLimitsPayload: Decodable {
        let primary: Entry?
        let secondary: Entry?

        struct Entry: Decodable {
            let usedPercent: Double?
            let windowMinutes: Double?
            let resetsAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowMinutes = "window_minutes"
                case resetsAt = "resets_at"
            }

            var limitWindow: LimitWindow? {
                guard let usedPercent, usedPercent.isFinite else { return nil }
                let reset = resetsAt.flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                return LimitWindow(usedPercent: usedPercent, resetsAt: reset)
            }

            /// Classify by duration, tolerating small drift in what the server reports.
            var scale: WindowScale {
                guard let windowMinutes, windowMinutes > 0 else { return .unknown }
                if windowMinutes.isWithin10Percent(of: 300) { return .fiveHour }
                if windowMinutes.isWithin10Percent(of: 10080) { return .sevenDay }
                return .unknown
            }
        }
    }

    enum WindowScale {
        case fiveHour   // window_minutes == 300
        case sevenDay   // window_minutes == 10080
        case unknown
    }
}

private extension Double {
    func isWithin10Percent(of target: Double) -> Bool {
        abs(self - target) <= target * 0.1
    }
}
