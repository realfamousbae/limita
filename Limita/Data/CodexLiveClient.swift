import Foundation

/// Fetches current Codex rate limits from the Codex CLI's own app server
/// (`codex app-server`, JSON-RPC over stdio, method `account/rateLimits/read`).
///
/// Unlike the session logs, this asks the backend, so the numbers are current even
/// when Codex has not been used for hours. Authentication stays inside the CLI.
struct CodexLiveClient: Sendable {
    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var timeout: TimeInterval = 20
    /// Injectable so tests never start the real CLI.
    var findExecutable: @Sendable () -> URL? = { CLILocator.find("codex") }

    func fetch(now: Date = Date()) throws -> LiveReading {
        guard let executable = findExecutable() else {
            throw FetchError(message: "Codex CLI not found")
        }
        let response = try JSONRPCSession.request(
            executable: executable,
            arguments: ["app-server"],
            messages: [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"limita","title":"Limita","version":"1.0"},"capabilities":null}}"#,
                #"{"jsonrpc":"2.0","method":"initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#,
            ],
            responseID: 2,
            timeout: timeout
        )
        return try Self.reading(fromResponse: response, capturedAt: now)
    }

    static func reading(fromResponse data: Data, capturedAt: Date) throws -> LiveReading {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if let error = envelope.error {
            throw FetchError(message: "Codex: \(error.message ?? "app-server error")")
        }
        guard let result = envelope.result else {
            throw FetchError(message: "Codex app-server returned an empty response")
        }
        let limits = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        let payload = CodexLimitsReader.RateLimitsPayload(
            primary: limits?.primary?.entry,
            secondary: limits?.secondary?.entry
        )
        let snapshot = CodexLimitsReader.snapshot(from: payload, capturedAt: capturedAt)
        guard !snapshot.isEmpty else {
            throw FetchError(message: "Codex app-server returned no limit windows")
        }

        var details = AccountDetails()
        details.limitResets = result.rateLimitResetCredits?.availableCount
        if let credits = limits?.credits {
            details.codexCreditsUnlimited = credits.unlimited ?? false
            // `balance` is a decimal string of credits, as the CLI's /status shows it.
            details.codexCredits = credits.balance.flatMap(Double.init)
        }
        return LiveReading(snapshot: snapshot, details: details)
    }

    // MARK: - Wire format (camelCase, unlike the session logs)

    private struct Envelope: Decodable {
        let result: Result?
        let error: RPCError?
    }

    private struct RPCError: Decodable {
        let message: String?
    }

    private struct Result: Decodable {
        let rateLimits: Limits?
        let rateLimitsByLimitId: [String: Limits]?
        let rateLimitResetCredits: ResetCredits?
    }

    private struct Limits: Decodable {
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
    }

    private struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?
    }

    private struct ResetCredits: Decodable {
        let availableCount: Int?
    }

    private struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Double?
        let resetsAt: Double?

        var entry: CodexLimitsReader.RateLimitsPayload.Entry {
            .init(usedPercent: usedPercent, windowMinutes: windowDurationMins, resetsAt: resetsAt)
        }
    }
}

/// Runs a stdio JSON-RPC server just long enough to get one response.
enum JSONRPCSession {
    static func request(
        executable: URL,
        arguments: [String],
        messages: [String],
        responseID: Int,
        timeout: TimeInterval
    ) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CLILocator.environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let collector = LineCollector(responseID: responseID)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collector.finish()
            } else {
                collector.append(chunk)
            }
        }

        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        signal(SIGPIPE, SIG_IGN)
        let payload = messages.map { $0 + "\n" }.joined()
        try stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8))

        guard collector.wait(timeout: timeout) else {
            throw CodexLiveClient.FetchError(message: "Codex app-server did not respond within \(Int(timeout)) s")
        }
        guard let response = collector.response else {
            throw CodexLiveClient.FetchError(message: "Codex app-server exited without a response")
        }
        return response
    }

    /// Splits stdout into lines and keeps the one answering `responseID`.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private let responseID: Int
        private var buffer = Data()
        private var finished = false
        private(set) var response: Data?

        init(responseID: Int) {
            self.responseID = responseID
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let id = (try? JSONDecoder().decode(IDOnly.self, from: line))?.id, id == responseID {
                    response = Data(line)
                    finishLocked()
                    return
                }
            }
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            finishLocked()
        }

        func wait(timeout: TimeInterval) -> Bool {
            done.wait(timeout: .now() + timeout) == .success
        }

        private func finishLocked() {
            guard !finished else { return }
            finished = true
            done.signal()
        }

        private struct IDOnly: Decodable {
            let id: Int?
        }
    }
}

/// Finds CLI tools for a GUI app, which does not inherit the shell's PATH.
enum CLILocator {
    static let searchDirectories: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin",
        ]
    }()

    /// PATH for child processes, so script-based CLIs can find `node` and friends.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let inherited = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (searchDirectories + inherited).joined(separator: ":")
        return environment
    }

    static func find(_ name: String) -> URL? {
        let fileManager = FileManager.default
        for directory in searchDirectories {
            let path = "\(directory)/\(name)"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
