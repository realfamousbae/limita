import Foundation

/// Tokens per local day for each service, read from the CLIs' own session logs.
///
/// - Claude Code: every assistant line in `~/.claude/projects/*/*.jsonl` carries the
///   request's `usage`. Resumed and forked sessions copy earlier lines into new files,
///   so a request is counted once by `message.id` + `requestId`, whatever file it is in.
/// - Codex: `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl` carry the
///   session's running total; a day gets the growth of that total during it.
///
/// Tokens are everything the model processed: input, output, cache writes and cache
/// reads (Codex counts cached input inside its input). Claude Code deletes old
/// transcripts (30 days by default), so the totals are kept in `activity.json`: a day
/// is only ever raised, never lowered because its files are gone.
final class ActivityReader: @unchecked Sendable {
    typealias Days = [DayKey: Int]

    private let claudeProjects: URL
    private let codexDirectories: [URL]
    private let historyURL: URL
    private let lock = NSLock()
    /// Parsed files, so a scan only reads what changed since the last one.
    private var claudeFiles: [String: CachedFile<[String: ClaudeRequest]>] = [:]
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
        let formatter = DayKeys.formatter(timeZone: timeZone)
        var history = loadHistory()
        for service in services {
            let scanned = service == .claude ? scanClaude(formatter) : scanCodex(formatter)
            history[service.rawValue] = Self.merge(history[service.rawValue] ?? [:], scanned)
        }
        saveHistory(history)
        return Dictionary(uniqueKeysWithValues: services.map { ($0, history[$0.rawValue] ?? [:]) })
    }

    /// A day keeps the larger of its saved and scanned totals.
    static func merge(_ saved: Days, _ scanned: Days) -> Days {
        saved.merging(scanned, uniquingKeysWith: max)
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

    struct ClaudeRequest: Equatable {
        let day: DayKey
        let tokens: Int
    }

    private func scanClaude(_ formatter: DateFormatter) -> Days {
        let files = Self.jsonlFiles(in: claudeProjects) { _ in true }
        claudeFiles = Self.refresh(claudeFiles, files: files) { Self.claudeRequests(in: $0, formatter: formatter) }
        var requests: [String: ClaudeRequest] = [:]
        for file in claudeFiles.values {
            requests.merge(file.value) { first, _ in first }
        }
        var days: Days = [:]
        for request in requests.values {
            days[request.day, default: 0] += request.tokens
        }
        return days
    }

    /// Requests in one transcript, by `message.id` + `requestId`.
    static func claudeRequests(in data: Data, formatter: DateFormatter) -> [String: ClaudeRequest] {
        var requests: [String: ClaudeRequest] = [:]
        forEachLine(in: data, containing: #""usage""#) { object in
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let date = ISO8601DateFormatter.parseFlexible(timestamp)
            else { return }
            let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            let id = "\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? object["uuid"] as? String ?? "")"
            requests[id] = ClaudeRequest(day: formatter.string(from: date), tokens: tokens)
        }
        return requests
    }

    // MARK: - Codex

    private func scanCodex(_ formatter: DateFormatter) -> Days {
        let files = codexDirectories.flatMap { directory in
            Self.jsonlFiles(in: directory) { $0.lastPathComponent.hasPrefix("rollout-") }
        }
        codexFiles = Self.refresh(codexFiles, files: files) { Self.codexDays(in: $0, formatter: formatter) }
        var days: Days = [:]
        for file in codexFiles.values {
            days.merge(file.value, uniquingKeysWith: +)
        }
        return days
    }

    /// Growth of the session's running total, by the day of each `token_count` event.
    /// Repeated events with the same total add nothing.
    static func codexDays(in data: Data, formatter: DateFormatter) -> Days {
        var days: Days = [:]
        var previous = 0
        forEachLine(in: data, containing: #""token_count""#) { object in
            guard let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let total = (usage["total_tokens"] as? NSNumber)?.intValue,
                  let timestamp = object["timestamp"] as? String,
                  let date = ISO8601DateFormatter.parseFlexible(timestamp)
            else { return }
            // A smaller total means the count started over.
            let growth = total >= previous ? total - previous : total
            previous = total
            if growth > 0 { days[formatter.string(from: date), default: 0] += growth }
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
