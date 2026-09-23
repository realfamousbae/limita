import XCTest
@testable import Limita

final class LimitaTests: XCTestCase {
    func testTailLineReaderReadsBackwardsAcrossSmallChunks() throws {
        let file = try temporaryFile(contents: "первая\nsecond\nтретья\n")
        XCTAssertEqual(Array(TailLineReader(url: file, chunkSize: 3)), ["третья", "second", "первая"])
    }

    func testCodexReaderSkipsNewestSessionWithoutLimits() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions/2026/09/19")
        let archived = root.appendingPathComponent("archived")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

        let valid = sessions.appendingPathComponent("rollout-old.jsonl")
        let empty = sessions.appendingPathComponent("rollout-new.jsonl")
        let record = """
        {"payload":{"rate_limits":{"primary":{"used_percent":42,"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":73,"window_minutes":10080,"resets_at":1894060800}}}}
        """
        try Data(record.utf8).write(to: valid)
        try Data("{\"payload\":{}}".utf8).write(to: empty)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: valid.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: empty.path)

        let state = CodexLimitsReader(
            sessionsDirectory: root.appendingPathComponent("sessions"),
            archivedSessionsDirectory: archived
        ).read(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(state.snapshot?.fiveHour?.usedPercent, 42)
        XCTAssertEqual(state.snapshot?.sevenDay?.usedPercent, 73)
    }

    func testClaudeCaptureKeepsOnlyRateLimitsAndReaderReturnsFreshSnapshot() throws {
        let destination = try temporaryDirectory().appendingPathComponent("claude.json")
        let input = """
        {
          "session_id":"secret-session",
          "transcript_path":"/private/transcript.jsonl",
          "rate_limits":{
            "five_hour":{"used_percentage":18.5,"resets_at":"2030-01-01T10:00:00Z"},
            "seven_day":{"used_percentage":64,"resets_at":"2030-01-07T10:00:00.123Z"}
          }
        }
        """
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try ClaudeStatusCapture.capture(input: Data(input.utf8), destination: destination, now: now)

        let persisted = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(persisted.contains("secret-session"))
        XCTAssertFalse(persisted.contains("transcript"))

        let state = ClaudeLimitsReader(cacheFile: destination).read(now: now.addingTimeInterval(60))
        XCTAssertEqual(state.snapshot?.fiveHour?.usedPercent, 18.5)
        XCTAssertEqual(state.snapshot?.sevenDay?.usedPercent, 64)
        XCTAssertFalse(state.isStale)
    }

    func testClaudeConfiguratorRefusesToOverwriteExistingStatusLine() throws {
        let root = try temporaryDirectory()
        let settings = root.appendingPathComponent("settings.json")
        try Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"my-status\"}}".utf8).write(to: settings)

        let configurator = ClaudeStatusLineConfigurator(
            settingsFile: settings,
            executableURL: URL(fileURLWithPath: "/Applications/Limita.app/Contents/MacOS/Limita")
        )
        XCTAssertThrowsError(try configurator.configure())

        let contents = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(contents.contains("my-status"))
        XCTAssertFalse(contents.contains("Limita.app"))
    }

    func testClaudeCaptureDoesNotReplaceGoodCacheWhenLimitsAreMissing() throws {
        let destination = try temporaryDirectory().appendingPathComponent("claude.json")
        let valid = """
        {"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":"2030-01-01T10:00:00Z"}}}
        """
        try ClaudeStatusCapture.capture(input: Data(valid.utf8), destination: destination)
        let original = try Data(contentsOf: destination)

        try ClaudeStatusCapture.capture(input: Data("{\"rate_limits\":null}".utf8), destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testClaudeCaptureAcceptsNestedUtilizationShape() throws {
        let destination = try temporaryDirectory().appendingPathComponent("claude.json")
        let input = """
        {"rate_limits":{"limits":{"five_hour":{"utilization":0.4,"resets_at":1893456000}}}}
        """
        try ClaudeStatusCapture.capture(input: Data(input.utf8), destination: destination)

        let state = ClaudeLimitsReader(cacheFile: destination).read()
        XCTAssertEqual(state.snapshot?.fiveHour?.usedPercent, 40)
        XCTAssertEqual(state.snapshot?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func temporaryFile(contents: String) throws -> URL {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("fixture.txt")
        try Data(contents.utf8).write(to: file)
        return file
    }
}
