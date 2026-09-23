import Foundation

/// `Limita --capture-claude-status [-- '<wrapped command>']`, run by Claude Code as its
/// status-line command.
///
/// Claude Code pipes a JSON payload to stdin and shows whatever the command prints.
/// Limita stores the rate limits from that payload, then either runs the user's own
/// status-line command with the same stdin (so their status line keeps working) or,
/// with nothing to wrap, prints a short summary of the limits itself.
enum ClaudeStatusLineCommand {
    static let flag = "--capture-claude-status"
    static let wrapSeparator = "--"

    /// Returns the process exit code. Capture failures are reported on stderr but never
    /// block the wrapped command: the user's status line matters more than our cache.
    static func run(
        arguments: [String],
        input: Data,
        cacheFile: URL = ClaudeStatusCache.fileURL,
        output: FileHandle = .standardOutput,
        now: Date = Date()
    ) -> Int32 {
        var cache: ClaudeStatusCache?
        do {
            cache = try ClaudeStatusCapture.capture(input: input, destination: cacheFile, now: now)
        } catch {
            FileHandle.standardError.write(Data("Limita: \(error.localizedDescription)\n".utf8))
        }

        if let wrapped = wrappedCommand(in: arguments) {
            return runShell(wrapped, input: input, output: output)
        }
        if let summary = cache.map(summary) {
            output.write(Data((summary + "\n").utf8))
        }
        return EXIT_SUCCESS
    }

    static func wrappedCommand(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag),
              let separator = arguments[flagIndex...].firstIndex(of: wrapSeparator),
              separator + 1 < arguments.count
        else { return nil }
        let command = arguments[separator + 1]
        return command.isEmpty ? nil : command
    }

    static func summary(of cache: ClaudeStatusCache) -> String {
        [("5h", cache.fiveHour), ("7d", cache.sevenDay)]
            .compactMap { label, window in window.map { "\(label) \($0.percentText(at: cache.capturedAt))" } }
            .joined(separator: " · ")
    }

    private static func runShell(_ command: String, input: Data, output: FileHandle) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("Limita: could not run the status line: \(error)\n".utf8))
            return EXIT_FAILURE
        }
        // The command may exit without reading stdin; a closed pipe must not kill us.
        signal(SIGPIPE, SIG_IGN)
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum ClaudeStatusCapture {
    /// Persists the rate limits from a status-line payload. Returns what was written, or
    /// `nil` when the payload carried no limits — the previous cache is then kept, since
    /// Claude Code omits limits until the first response of a session.
    @discardableResult
    static func capture(input: Data, destination: URL, now: Date = Date()) throws -> ClaudeStatusCache? {
        let payload = try JSONDecoder().decode(StatusLineInput.self, from: input)
        let cache = ClaudeStatusCache(
            fiveHour: payload.rateLimits?.resolvedFiveHour?.limitWindow,
            sevenDay: payload.rateLimits?.resolvedSevenDay?.limitWindow,
            capturedAt: now
        )
        guard !cache.snapshot.isEmpty else { return nil }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ClaudeStatusCache.encoder.encode(cache).write(to: destination, options: [.atomic])
        return cache
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
            usedPercentage = try? container.decodeIfPresent(Double.self, forKey: .usedPercentage)
            utilization = try? container.decodeIfPresent(Double.self, forKey: .utilization)

            if let value = try? container.decode(String.self, forKey: .resetsAt) {
                resetsAt = ISO8601DateFormatter.parseFlexible(value)
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
    }
}

/// Installs Limita as Claude Code's status-line command in `~/.claude/settings.json`.
///
/// An existing status line is wrapped rather than replaced, and restored on removal.
struct ClaudeStatusLineConfigurator {
    enum Status: Equatable {
        case notConfigured
        /// Someone else's status line; installing will wrap it.
        case foreign(command: String)
        case installed(executablePath: String, wrapped: String?)
    }

    enum Outcome: Equatable {
        case installed
        case wrapped
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

    /// Only an installed app has a stable path. Builds in DerivedData, tmp or Downloads
    /// disappear or move, and a hook pointing there silently blanks the status line.
    var isRunningFromStableLocation: Bool {
        let path = executableURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path + "/"
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications)
    }

    func status() throws -> Status {
        try Self.status(of: loadSettings())
    }

    func install() throws -> Outcome {
        var settings = try loadSettings()
        var statusLine = settings["statusLine"] as? [String: Any] ?? ["type": "command"]
        let outcome: Outcome
        let wrapped: String?

        switch Self.status(of: settings) {
        case .notConfigured:
            outcome = .installed
            wrapped = nil
        case .foreign(let command):
            outcome = .wrapped
            wrapped = command
        case .installed(let path, let existing):
            if path == executableURL.path { return .alreadyConfigured }
            outcome = .updated
            wrapped = existing
        }

        statusLine["type"] = "command"
        statusLine["command"] = command(wrapping: wrapped)
        settings["statusLine"] = statusLine
        try write(settings)
        return outcome
    }

    /// Restores the wrapped status line, or removes ours if there was none.
    func uninstall() throws {
        var settings = try loadSettings()
        guard case .installed(_, let wrapped) = Self.status(of: settings) else { return }
        if let wrapped, var statusLine = settings["statusLine"] as? [String: Any] {
            statusLine["command"] = wrapped
            settings["statusLine"] = statusLine
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try write(settings)
    }

    /// Re-points an installed hook whose executable no longer exists (the app was moved
    /// or rebuilt elsewhere). Returns whether anything changed.
    @discardableResult
    func repairIfNeeded() throws -> Bool {
        guard case .installed(let path, _) = try status(),
              path != executableURL.path,
              !FileManager.default.fileExists(atPath: path),
              isRunningFromStableLocation
        else { return false }
        return try install() == .updated
    }

    func command(wrapping wrapped: String?) -> String {
        var words = [executableURL.path, ClaudeStatusLineCommand.flag]
        if let wrapped {
            words += [ClaudeStatusLineCommand.wrapSeparator, wrapped]
        }
        return words.map(ShellWords.quote).joined(separator: " ")
    }

    // MARK: - Settings file

    private static func status(of settings: [String: Any]) -> Status {
        guard let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return .notConfigured }

        guard let words = ShellWords.split(command),
              words.count >= 2,
              words[1] == ClaudeStatusLineCommand.flag
        else { return .foreign(command: command) }

        return .installed(executablePath: words[0], wrapped: ClaudeStatusLineCommand.wrappedCommand(in: words))
    }

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return [:] }
        let data = try Data(contentsOf: settingsFile)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError(message: "Could not read ~/.claude/settings.json: it is not a JSON object.")
        }
        return object
    }

    private func write(_ settings: [String: Any]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Keep the user's original settings once, before our first change.
        let backup = settingsFile.appendingPathExtension("limita-backup")
        if fileManager.fileExists(atPath: settingsFile.path), !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: settingsFile, to: backup)
        }

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsFile, options: [.atomic])
    }
}

/// Minimal POSIX-shell word quoting/splitting — enough to round-trip the commands we write.
enum ShellWords {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits on unquoted whitespace, honouring single quotes, double quotes and
    /// backslash escapes. Returns `nil` for unbalanced quotes.
    static func split(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = command.makeIterator()

        while let character = iterator.next() {
            switch character {
            case "'":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "'" { closed = true; break }
                    current.append(next)
                }
                guard closed else { return nil }
            case "\"":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "\"" { closed = true; break }
                    if next == "\\", let escaped = iterator.next() {
                        if !"\"\\$`".contains(escaped) { current.append("\\") }
                        current.append(escaped)
                    } else {
                        current.append(next)
                    }
                }
                guard closed else { return nil }
            case "\\":
                inWord = true
                if let escaped = iterator.next() { current.append(escaped) }
            case _ where character.isWhitespace:
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                inWord = true
                current.append(character)
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
