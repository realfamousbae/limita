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

        let state = ClaudeLimitsReader(cacheFile: destination).read(isConnected: true, now: now.addingTimeInterval(60))
        XCTAssertEqual(state.snapshot?.fiveHour?.usedPercent, 18.5)
        XCTAssertEqual(state.snapshot?.sevenDay?.usedPercent, 64)
        XCTAssertFalse(state.isStale)
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

        let state = ClaudeLimitsReader(cacheFile: destination).read(isConnected: true)
        XCTAssertEqual(state.snapshot?.fiveHour?.usedPercent, 40)
        XCTAssertEqual(state.snapshot?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    // MARK: - Codex

    func testCodexReaderSkipsBucketsWithoutWindowsAndUsesRecordTimestamp() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-a.jsonl")
        let lines = [
            #"{"timestamp":"2026-09-23T11:29:40.211Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1790180964},"secondary":{"used_percent":98.0,"window_minutes":10080,"resets_at":1790268541}}}}"#,
            #"{"timestamp":"2026-09-23T11:30:00Z","payload":{"type":"message","text":"hello"}}"#,
            #"{"timestamp":"2026-09-23T11:31:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)

        let state = CodexLimitsReader(
            sessionsDirectory: sessions,
            archivedSessionsDirectory: root.appendingPathComponent("missing")
        ).read(now: ISO8601DateFormatter.parseFlexible("2026-09-23T11:35:00Z")!)

        XCTAssertEqual(state.snapshot?.fiveHour?.usedPercent, 1)
        XCTAssertEqual(state.snapshot?.sevenDay?.usedPercent, 98)
        XCTAssertEqual(state.snapshot?.capturedAt, ISO8601DateFormatter.parseFlexible("2026-09-23T11:29:40.211Z"))
        XCTAssertFalse(state.isStale)
    }

    func testExpiredWindowDisplaysZero() {
        let window = LimitWindow(usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(window.displayPercent(at: Date(timeIntervalSince1970: 999)), 80)
        XCTAssertEqual(window.displayPercent(at: Date(timeIntervalSince1970: 1000)), 0)
        XCTAssertEqual(window.resetText(at: Date(timeIntervalSince1970: 2000)), "окно обновилось")
    }

    // MARK: - Claude status line

    func testConfiguratorWrapsExistingStatusLineAndRestoresIt() throws {
        let settings = try temporaryDirectory().appendingPathComponent("settings.json")
        let original = #"jq -r '"[\(.model.display_name)] \(.context_window.used_percentage // 0)% context"'"#
        let json = try JSONSerialization.data(withJSONObject: [
            "model": "opus",
            "statusLine": ["type": "command", "command": original, "padding": 2],
        ])
        try json.write(to: settings)

        let configurator = ClaudeStatusLineConfigurator(
            settingsFile: settings,
            executableURL: URL(fileURLWithPath: "/Applications/Limita.app/Contents/MacOS/Limita")
        )
        XCTAssertEqual(try configurator.status(), .foreign(command: original))
        XCTAssertEqual(try configurator.install(), .wrapped)
        XCTAssertEqual(
            try configurator.status(),
            .installed(executablePath: "/Applications/Limita.app/Contents/MacOS/Limita", wrapped: original)
        )
        XCTAssertEqual(try configurator.install(), .alreadyConfigured)

        let installed = try settingsObject(settings)
        XCTAssertEqual(installed["model"] as? String, "opus")
        XCTAssertEqual((installed["statusLine"] as? [String: Any])?["padding"] as? Int, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path + ".limita-backup"))

        try configurator.uninstall()
        XCTAssertEqual(try configurator.status(), .foreign(command: original))
        XCTAssertEqual((try settingsObject(settings)["statusLine"] as? [String: Any])?["padding"] as? Int, 2)
    }

    func testConfiguratorInstallsAloneAndUninstallRemovesIt() throws {
        let settings = try temporaryDirectory().appendingPathComponent("settings.json")
        let configurator = ClaudeStatusLineConfigurator(
            settingsFile: settings,
            executableURL: URL(fileURLWithPath: "/Applications/Lim'ita.app/Contents/MacOS/Limita")
        )
        XCTAssertEqual(try configurator.install(), .installed)
        XCTAssertEqual(
            try configurator.status(),
            .installed(executablePath: "/Applications/Lim'ita.app/Contents/MacOS/Limita", wrapped: nil)
        )
        try configurator.uninstall()
        XCTAssertEqual(try configurator.status(), .notConfigured)
        XCTAssertNil(try settingsObject(settings)["statusLine"])
    }

    func testConfiguratorUpdatesPathOfMovedApp() throws {
        let settings = try temporaryDirectory().appendingPathComponent("settings.json")
        let old = ClaudeStatusLineConfigurator(settingsFile: settings, executableURL: URL(fileURLWithPath: "/old/Limita"))
        let new = ClaudeStatusLineConfigurator(settingsFile: settings, executableURL: URL(fileURLWithPath: "/Applications/Limita.app/Contents/MacOS/Limita"))
        XCTAssertEqual(try old.install(), .installed)
        XCTAssertTrue(try new.repairIfNeeded())
        XCTAssertEqual(
            try new.status(),
            .installed(executablePath: "/Applications/Limita.app/Contents/MacOS/Limita", wrapped: nil)
        )
    }

    func testConfiguratorRejectsNonObjectSettings() throws {
        let settings = try temporaryDirectory().appendingPathComponent("settings.json")
        try Data("[1,2]".utf8).write(to: settings)
        let configurator = ClaudeStatusLineConfigurator(settingsFile: settings, executableURL: URL(fileURLWithPath: "/x"))
        XCTAssertThrowsError(try configurator.install())
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "[1,2]")
    }

    func testCommandRunsWrappedStatusLineWithSameInput() throws {
        let directory = try temporaryDirectory()
        let cache = directory.appendingPathComponent("claude.json")
        let outputURL = directory.appendingPathComponent("out.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)

        let input = #"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1893456000}}}"#
        let status = ClaudeStatusLineCommand.run(
            arguments: ["/x/Limita", "--capture-claude-status", "--", #"sed 's/.*display_name":"\([^"]*\)".*/[\1]/'"#],
            input: Data(input.utf8),
            cacheFile: cache,
            output: output
        )
        try output.close()

        XCTAssertEqual(status, 0)
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "[Opus]")
        XCTAssertEqual(ClaudeLimitsReader(cacheFile: cache).read(isConnected: true).snapshot?.fiveHour?.usedPercent, 12)
    }

    func testCommandPrintsSummaryWithoutWrappedStatusLine() throws {
        let directory = try temporaryDirectory()
        let outputURL = directory.appendingPathComponent("out.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)

        let input = #"{"rate_limits":{"five_hour":{"used_percentage":12.4},"seven_day":{"used_percentage":40}}}"#
        _ = ClaudeStatusLineCommand.run(
            arguments: ["/x/Limita", "--capture-claude-status"],
            input: Data(input.utf8),
            cacheFile: directory.appendingPathComponent("claude.json"),
            output: output
        )
        try output.close()
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "5h 12% · 7d 40%\n")
    }

    func testShellWordsRoundTrip() {
        let words = ["/Applications/My App.app/Limita", "--capture-claude-status", "--", #"jq -r '"\(.a) it's"'"#]
        let command = words.map(ShellWords.quote).joined(separator: " ")
        XCTAssertEqual(ShellWords.split(command), words)
        XCTAssertEqual(ShellWords.split(#"a "b \"c\"" d\ e"#), ["a", #"b "c""#, "d e"])
        XCTAssertNil(ShellWords.split("a 'b"))
    }

    // MARK: - Layout

    func testTriggerIgnoresNotchArea() {
        let layout = PanelLayout(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            menuBarHeight: 37,
            notchSpan: 660...852
        )
        XCTAssertTrue(layout.isTrigger(CGPoint(x: 200, y: 981)))
        XCTAssertTrue(layout.isTrigger(CGPoint(x: 1400, y: 981)))
        XCTAssertFalse(layout.isTrigger(CGPoint(x: 756, y: 981)))
        XCTAssertFalse(layout.isTrigger(CGPoint(x: 600, y: 981)), "clearance around the notch")
        XCTAssertFalse(layout.isTrigger(CGPoint(x: 200, y: 900)), "not at the edge")
    }

    func testFrameStaysOutOfNotchAndOnScreen() {
        let layout = PanelLayout(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            menuBarHeight: 37,
            notchSpan: 660...852
        )
        let excluded = layout.excludedSpan!
        let size = CGSize(width: 520, height: 212)

        for anchor in stride(from: CGFloat(0), through: 1512, by: 37) {
            let frame = layout.frame(size: size, anchorX: anchor)
            XCTAssertFalse(frame.maxX > excluded.lowerBound && frame.minX < excluded.upperBound, "overlaps notch at \(anchor)")
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, 1512)
            XCTAssertEqual(frame.maxY, 982 - 37 - PanelLayout.gapBelowMenuBar)
        }
        XCTAssertLessThan(layout.frame(size: size, anchorX: 700).maxX, excluded.lowerBound + 1)
        XCTAssertGreaterThan(layout.frame(size: size, anchorX: 800).minX, excluded.upperBound - 1)
    }

    func testFrameCentresOnAnchorWithoutNotch() {
        let layout = PanelLayout(screenFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), menuBarHeight: 24, notchSpan: nil)
        XCTAssertEqual(layout.frame(size: CGSize(width: 200, height: 34), anchorX: 2472).midX, 2472)
        XCTAssertTrue(layout.isTrigger(CGPoint(x: 2472, y: 1079)))
    }

    // MARK: - Helpers

    private func settingsObject(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
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
