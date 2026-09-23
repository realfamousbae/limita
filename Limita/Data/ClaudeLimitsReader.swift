import Foundation

/// Reads the sanitized payload written by Limita's Claude Code status-line hook.
struct ClaudeLimitsReader: Sendable {
    static let staleAfter: TimeInterval = 30 * 60

    let cacheFile: URL

    init(cacheFile: URL = ClaudeStatusCache.fileURL) {
        self.cacheFile = cacheFile
    }

    func read(now: Date = Date()) -> ServiceState {
        guard let data = try? Data(contentsOf: cacheFile) else {
            return .unavailable(reason: "Подключите Claude Code, чтобы получать его лимиты")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(ClaudeStatusCache.self, from: data) else {
            return .unavailable(reason: "Кэш Claude повреждён — подключите Claude Code заново")
        }

        let snapshot = cache.snapshot
        guard !snapshot.isEmpty else {
            return .unavailable(reason: "Claude Code пока не передал данные о лимитах")
        }
        return .from(snapshot, staleAfter: Self.staleAfter, now: now)
    }
}

/// The only data persisted from Claude's status-line JSON. No transcript, prompt,
/// project path, account information, or credential is retained.
struct ClaudeStatusCache: Codable, Sendable, Equatable {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
    let capturedAt: Date

    var snapshot: LimitSnapshot {
        LimitSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, capturedAt: capturedAt)
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limita", isDirectory: true)
            .appendingPathComponent("claude-status.json")
    }
}

enum ClaudeStatusCapture {
    static func capture(
        input: Data = FileHandle.standardInput.readDataToEndOfFile(),
        destination: URL = ClaudeStatusCache.fileURL,
        now: Date = Date()
    ) throws {
        let payload = try JSONDecoder().decode(StatusLineInput.self, from: input)
        let cache = ClaudeStatusCache(
            fiveHour: payload.rateLimits?.resolvedFiveHour?.limitWindow,
            sevenDay: payload.rateLimits?.resolvedSevenDay?.limitWindow,
            capturedAt: now
        )
        guard !cache.snapshot.isEmpty else { return }

        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(cache).write(to: destination, options: [.atomic])
    }

    struct StatusLineInput: Decodable {
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let fiveHour: Entry?
        let sevenDay: Entry?
        let limits: WindowSet?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }

        var resolvedFiveHour: Entry? { fiveHour ?? limits?.fiveHour }
        var resolvedSevenDay: Entry? { sevenDay ?? limits?.sevenDay }
    }

    struct WindowSet: Decodable {
        let fiveHour: Entry?
        let sevenDay: Entry?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    struct Entry: Decodable {
        let usedPercentage: Double?
        let utilization: Double?
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercentage = try container.decodeIfPresent(Double.self, forKey: .usedPercentage)
            utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)

            if let value = try? container.decode(String.self, forKey: .resetsAt) {
                resetsAt = Self.parseDate(value)
            } else if let value = try? container.decode(Double.self, forKey: .resetsAt) {
                resetsAt = Date(timeIntervalSince1970: value)
            } else {
                resetsAt = nil
            }
        }

        var limitWindow: LimitWindow? {
            let percentage = usedPercentage ?? utilization.map { $0 <= 1 ? $0 * 100 : $0 }
            guard let percentage, percentage.isFinite else { return nil }
            return LimitWindow(usedPercent: percentage, resetsAt: resetsAt)
        }

        private static func parseDate(_ value: String) -> Date? {
            ISO8601DateFormatter.withFractionalSeconds.date(from: value)
                ?? ISO8601DateFormatter().date(from: value)
        }
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct ClaudeStatusLineConfigurator {
    enum Outcome {
        case installed
        case updated
        case alreadyConfigured
    }

    struct ConfigurationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let settingsFile: URL
    private let executableURL: URL

    init(
        settingsFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) {
        self.settingsFile = settingsFile
        self.executableURL = executableURL
    }

    func configure() throws -> Outcome {
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsFile.path) {
            let data = try Data(contentsOf: settingsFile)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigurationError(message: "Файл ~/.claude/settings.json имеет неподдерживаемый формат.")
            }
            settings = object
        }

        let command = "\(shellQuote(executableURL.path)) --capture-claude-status"
        if let existing = settings["statusLine"] as? [String: Any],
           let existingCommand = existing["command"] as? String {
            if existingCommand == command { return .alreadyConfigured }
            guard existingCommand.contains("--capture-claude-status") else {
                throw ConfigurationError(
                    message: "В Claude Code уже настроена своя status line. Limita не стала её перезаписывать."
                )
            }
            settings["statusLine"] = ["type": "command", "command": command]
            try write(settings)
            return .updated
        }

        settings["statusLine"] = ["type": "command", "command": command]
        try write(settings)
        return .installed
    }

    private func write(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsFile, options: [.atomic])
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
