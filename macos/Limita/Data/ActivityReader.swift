import Foundation

/// What one service did on one local day. Stored in `activity.json`; the same format
/// on Windows.
struct DayStats: Codable, Equatable, Sendable {
    /// Everything the model processed: the four kinds below added up.
    var tokens = 0
    /// Input not served from the cache.
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    /// Your prompts plus the model's replies.
    var messages = 0
    /// Tokens by model id.
    var models: [String: Int] = [:]
    /// Messages by local hour, 0...23.
    var hours: [Int] = Array(repeating: 0, count: 24)

    init() {}

    init(tokens: Int) {
        self.tokens = tokens
    }

    var isActive: Bool { tokens > 0 || messages > 0 }

    /// Days saved by 0.8.0 are a bare token count.
    init(from decoder: Decoder) throws {
        if let tokens = try? decoder.singleValueContainer().decode(Int.self) {
            self.init(tokens: tokens)
            return
        }
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheWrite = try container.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        messages = try container.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        models = try container.decodeIfPresent([String: Int].self, forKey: .models) ?? [:]
        let hours = try container.decodeIfPresent([Int].self, forKey: .hours) ?? []
        if hours.count == 24 { self.hours = hours }
    }

    /// Saved days are only ever raised: each count keeps the larger value.
    func merged(with other: DayStats) -> DayStats {
        var result = DayStats()
        result.tokens = max(tokens, other.tokens)
        result.input = max(input, other.input)
        result.output = max(output, other.output)
        result.cacheWrite = max(cacheWrite, other.cacheWrite)
        result.cacheRead = max(cacheRead, other.cacheRead)
        result.messages = max(messages, other.messages)
        result.models = models.merging(other.models, uniquingKeysWith: max)
        result.hours = zip(hours, other.hours).map { max($0, $1) }
        return result
    }

    mutating func add(_ event: ActivityEvent) {
        tokens += event.tokens
        input += event.usage.input
        output += event.usage.output
        cacheWrite += event.usage.cacheWrite
        cacheRead += event.usage.cacheRead
        if event.isMessage {
            messages += 1
            hours[event.hour] += 1
        }
        if let model = event.model, event.tokens > 0 { models[model, default: 0] += event.tokens }
    }
}

/// Tokens by kind.
struct TokenUsage: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite + cacheRead }

    func minus(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(0, input - other.input),
            output: max(0, output - other.output),
            cacheWrite: max(0, cacheWrite - other.cacheWrite),
            cacheRead: max(0, cacheRead - other.cacheRead)
        )
    }
}

/// One counted thing in a log: a request's tokens, a message, or both.
struct ActivityEvent: Equatable, Sendable {
    let day: DayKey
    let hour: Int
    var model: String?
    var usage = TokenUsage()
    var isMessage = false

    var tokens: Int { usage.total }
}

/// Activity per local day for each service, read from the CLIs' own session logs.
///
/// - Claude Code: every assistant line in `~/.claude/projects/**/*.jsonl` carries the
///   request's `usage` and model; user lines are your prompts. Resumed and forked
///   sessions copy earlier lines into new files, so a request is counted once by
///   `message.id` + `requestId` and a prompt once by its `uuid`, whatever file it is in.
/// - Codex: `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl` carry the
///   session's running total; a day gets the growth of that total during it. Messages
///   are `user_message` and `agent_message` events, the model comes from `turn_context`.
///
/// Claude Code deletes old transcripts (30 days by default), so the days are kept in
/// `activity.json` and only ever raised, never lowered because their files are gone.
final class ActivityReader: @unchecked Sendable {
    typealias Days = [DayKey: DayStats]

    private let claudeProjects: URL
    private let codexDirectories: [URL]
    private let historyURL: URL
    private let lock = NSLock()
    /// Parsed files, so a scan only reads what changed since the last one.
    private var claudeFiles: [String: CachedFile<[String: ActivityEvent]>] = [:]
    private var codexFiles: [String: CachedFile<Days>] = [:]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        historyURL: URL = ActivityReader.defaultHistoryURL
    ) {
        claudeProjects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        codexDirectories = [
            codex.appendingPathComponent("sessions", isDirectory: true),
            codex.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        self.historyURL = historyURL
    }

    static var defaultHistoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limita", isDirectory: true)
            .appendingPathComponent("activity.json")
    }

    /// Scans the logs of `services`, merges them into the saved history and returns it.
    /// Slow on first run (every log is parsed); call it off the main thread.
    func read(_ services: [Service], timeZone: TimeZone = .current) -> [Service: Days] {
        lock.lock()
        defer { lock.unlock() }
        let clock = LocalClock(timeZone: timeZone)
        var history = loadHistory()
        for service in services {
            let scanned = service == .claude ? scanClaude(clock) : scanCodex(clock)
            history[service.rawValue] = Self.merge(history[service.rawValue] ?? [:], scanned)
        }
        saveHistory(history)
        return Dictionary(uniqueKeysWithValues: services.map { ($0, history[$0.rawValue] ?? [:]) })
    }

    static func merge(_ saved: Days, _ scanned: Days) -> Days {
        saved.merging(scanned) { $0.merged(with: $1) }
    }

    // MARK: - History file

    private func loadHistory() -> [String: Days] {
        guard let data = try? Data(contentsOf: historyURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Days].self, from: data)) ?? [:]
    }

    private func saveHistory(_ history: [String: Days]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
    }

    // MARK: - Claude Code

    private func scanClaude(_ clock: LocalClock) -> Days {
        let files = Self.jsonlFiles(in: claudeProjects) { _ in true }
        claudeFiles = Self.refresh(claudeFiles, files: files) { Self.claudeEvents(in: $0, clock: clock) }
        var events: [String: ActivityEvent] = [:]
        for file in claudeFiles.values {
            events.merge(file.value) { first, _ in first }
        }
        var days: Days = [:]
        for event in events.values {
            days[event.day, default: DayStats()].add(event)
        }
        return days
    }

    /// Events in one transcript: requests by `message.id` + `requestId`, prompts by `uuid`.
    static func claudeEvents(in data: Data, clock: LocalClock) -> [String: ActivityEvent] {
        var events: [String: ActivityEvent] = [:]
        forEachLine(in: data, containing: #""type":"#) { object in
            guard let type = object["type"] as? String, type == "assistant" || type == "user",
                  let message = object["message"] as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let date = ISO8601DateFormatter.parseFlexible(timestamp)
            else { return }
            let (day, hour) = clock.dayAndHour(date)

            if type == "assistant" {
                guard let usage = message["usage"] as? [String: Any] else { return }
                func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
                let tokens = TokenUsage(
                    input: count("input_tokens"),
                    output: count("output_tokens"),
                    cacheWrite: count("cache_creation_input_tokens"),
                    cacheRead: count("cache_read_input_tokens")
                )
                let model = (message["model"] as? String).flatMap { $0.hasPrefix("<") ? nil : $0 }
                let id = "a|\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? object["uuid"] as? String ?? "")"
                events[id] = ActivityEvent(day: day, hour: hour, model: model, usage: tokens, isMessage: true)
            } else if isPrompt(object, message: message), let uuid = object["uuid"] as? String {
                events["u|\(uuid)"] = ActivityEvent(day: day, hour: hour, isMessage: true)
            }
        }
        return events
    }

    /// A line you typed: not a tool result, not a subagent's prompt, not command output.
    private static func isPrompt(_ object: [String: Any], message: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true || object["isSidechain"] as? Bool == true { return false }
        if let text = message["content"] as? String {
            return !text.hasPrefix("<local-command-")
        }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.contains { $0["type"] as? String == "text" }
                && !parts.contains { $0["type"] as? String == "tool_result" }
        }
        return false
    }

    // MARK: - Codex

    private func scanCodex(_ clock: LocalClock) -> Days {
        let files = codexDirectories.flatMap { directory in
            Self.jsonlFiles(in: directory) { $0.lastPathComponent.hasPrefix("rollout-") }
        }
        codexFiles = Self.refresh(codexFiles, files: files) { data in
            Self.codexDays(in: data, clock: clock)
        }
        var days: Days = [:]
        for file in codexFiles.values {
            days.merge(file.value) { first, second in
                var sum = first
                sum.tokens += second.tokens
                sum.input += second.input
                sum.output += second.output
                sum.cacheWrite += second.cacheWrite
                sum.cacheRead += second.cacheRead
                sum.messages += second.messages
                sum.models.merge(second.models, uniquingKeysWith: +)
                sum.hours = zip(first.hours, second.hours).map(+)
                return sum
            }
        }
        return days
    }

    /// One rollout is one session. Tokens are the growth of its running total by the day
    /// of each `token_count` event; repeated events with the same total add nothing.
    /// Codex counts cached input inside its input and writes no cache of its own, so
    /// cached input is a cache read and the rest is input.
    static func codexDays(in data: Data, clock: LocalClock) -> Days {
        var days: Days = [:]
        var previous = TokenUsage()
        var model: String?
        forEachLine(in: data, containing: #""payload""#) { object in
            guard let payload = object["payload"] as? [String: Any] else { return }
            let type = object["type"] as? String
            if type == "turn_context" {
                if let name = payload["model"] as? String { model = name }
                return
            }
            guard type == "event_msg",
                  let timestamp = object["timestamp"] as? String,
                  let date = ISO8601DateFormatter.parseFlexible(timestamp)
            else { return }
            let (day, hour) = clock.dayAndHour(date)
            var event = ActivityEvent(day: day, hour: hour, model: model)
            switch payload["type"] as? String {
            case "user_message", "agent_message":
                event.isMessage = true
            case "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any]
                else { return }
                func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
                let cached = count("cached_input_tokens")
                let total = TokenUsage(input: max(0, count("input_tokens") - cached), output: count("output_tokens"), cacheRead: cached)
                // A smaller total means the count started over.
                event.usage = total.total >= previous.total ? total.minus(previous) : total
                previous = total
                guard event.tokens > 0 else { return }
            default:
                return
            }
            days[day, default: DayStats()].add(event)
        }
        return days
    }

    // MARK: - Files

    struct CachedFile<Value> {
        let size: Int
        let modified: Date
        let value: Value
    }

    private struct FileInfo {
        let url: URL
        let size: Int
        let modified: Date
    }

    private static func jsonlFiles(in directory: URL, where include: (URL) -> Bool) -> [FileInfo] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [FileInfo] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && include(url) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append(FileInfo(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast))
        }
        return files
    }

    /// Keeps cached results of unchanged files, parses the rest and forgets deleted ones.
    private static func refresh<Value>(
        _ cache: [String: CachedFile<Value>], files: [FileInfo], parse: (Data) -> Value
    ) -> [String: CachedFile<Value>] {
        var next: [String: CachedFile<Value>] = [:]
        for file in files {
            let path = file.url.path
            if let cached = cache[path], cached.size == file.size, cached.modified == file.modified {
                next[path] = cached
            } else if let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) {
                next[path] = CachedFile(size: file.size, modified: file.modified, value: parse(data))
            }
        }
        return next
    }

    /// Calls `body` with each JSON object line that contains `needle`; the check skips
    /// most lines without parsing them.
    private static func forEachLine(in data: Data, containing needle: String, _ body: ([String: Any]) -> Void) {
        let needle = Data(needle.utf8)
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[start..<end]
            if line.range(of: needle) != nil,
               let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                body(object)
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
    }
}

/// Local day keys and hours, made once per scan: a `DateFormatter` per line is slow.
struct LocalClock {
    let formatter: DateFormatter
    let calendar: Calendar

    init(timeZone: TimeZone) {
        formatter = DayKeys.formatter(timeZone: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    func dayAndHour(_ date: Date) -> (DayKey, Int) {
        (formatter.string(from: date), calendar.component(.hour, from: date))
    }
}
