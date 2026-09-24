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

    func testCodexAppServerResponsePrefersCodexBucket() throws {
        let response = #"{"id":2,"result":{"rateLimits":{"limitId":"premium","primary":null,"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1790215642},"secondary":{"usedPercent":98,"windowDurationMins":10080,"resetsAt":1790268541}}}}}"#
        let now = Date(timeIntervalSince1970: 1_790_200_000)
        let snapshot = try CodexLiveClient.reading(fromResponse: Data(response.utf8), capturedAt: now).snapshot
        XCTAssertEqual(snapshot.fiveHour, LimitWindow(usedPercent: 3, resetsAt: Date(timeIntervalSince1970: 1_790_215_642)))
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 98)
        XCTAssertEqual(snapshot.capturedAt, now)

        let error = #"{"id":2,"error":{"code":-32600,"message":"not logged in"}}"#
        XCTAssertThrowsError(try CodexLiveClient.reading(fromResponse: Data(error.utf8), capturedAt: now))
    }

    func testClaudeUsageResponseIsParsedAsPercent() throws {
        let response = #"{"five_hour":{"utilization":1.0,"resets_at":"2026-09-24T04:59:59.943648+00:00"},"seven_day":{"utilization":37.0,"resets_at":"2026-09-28T11:00:00+00:00"},"seven_day_opus":null}"#
        let snapshot = try ClaudeLiveClient.reading(fromResponse: Data(response.utf8), capturedAt: Date()).snapshot
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 1, "utilization is already a percentage")
        XCTAssertEqual(
            snapshot.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0,
            ISO8601DateFormatter.parseFlexible("2026-09-24T04:59:59Z")!.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 37)
        XCTAssertThrowsError(try ClaudeLiveClient.reading(fromResponse: Data("{}".utf8), capturedAt: Date()))
    }

    func testCodexDetailsReadResetsAndCredits() throws {
        let response = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1790215642},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"250"}},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":2,"credits":null}}}"#
        let details = try CodexLiveClient.reading(fromResponse: Data(response.utf8), capturedAt: Date()).details
        XCTAssertEqual(details.limitResets, 2)
        XCTAssertEqual(details.codexCredits, 250)
        XCTAssertEqual(details.codexCredits.map { $0 / AccountDetails.codexCreditsPerDollar }, 10)
        XCTAssertFalse(details.codexCreditsUnlimited)
    }

    func testClaudeDetailsReadCloudAndUsageCredits() throws {
        // Trimmed from a real /api/oauth/usage response.
        let response = #"""
        {"five_hour":{"utilization":33.0,"resets_at":"2026-09-24T00:10:00.439325+00:00"},
         "seven_day":{"utilization":7.0,"resets_at":"2026-09-28T11:00:00.439346+00:00"},
         "iguana_necktie":{"utilization":4.910254,"resets_at":"2026-11-05T07:59:00+00:00","limit_dollars":100,"used_dollars":4.910254,"remaining_dollars":95.089746},
         "spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"enabled":false,"balance":null}}
        """#
        let details = try ClaudeLiveClient.reading(fromResponse: Data(response.utf8), capturedAt: Date()).details
        XCTAssertEqual(details.cloudCredits?.remaining ?? 0, 95.09, accuracy: 0.01)
        XCTAssertEqual(details.cloudCredits?.limit, 100)
        XCTAssertEqual(details.cloudCredits?.expiresAt, ISO8601DateFormatter.parseFlexible("2026-11-05T07:59:00Z"))
        XCTAssertEqual(details.claudeUsageCredits, .off)
        XCTAssertNil(details.limitResets)

        let enabled = #"{"five_hour":{"utilization":1},"spend":{"enabled":true,"used":{"amount_minor":1250,"exponent":2},"limit":{"amount_minor":5000,"exponent":2}}}"#
        XCTAssertEqual(
            try ClaudeLiveClient.reading(fromResponse: Data(enabled.utf8), capturedAt: Date()).details.claudeUsageCredits,
            .spent(dollars: 12.5, limit: 50)
        )

        let withBalance = #"{"five_hour":{"utilization":1},"spend":{"enabled":true,"balance":{"amount_minor":2000,"exponent":2}},"iguana_necktie":"unexpected"}"#
        let parsed = try ClaudeLiveClient.reading(fromResponse: Data(withBalance.utf8), capturedAt: Date()).details
        XCTAssertEqual(parsed.claudeUsageCredits, .balance(dollars: 20))
        XCTAssertNil(parsed.cloudCredits, "a changed shape hides the row instead of failing")
    }

    func testDetailRowsFormatting() {
        var codex = AccountDetails()
        codex.limitResets = 0
        codex.codexCredits = 250
        XCTAssertEqual(ExpandedView.detailRows(for: .codex, details: codex).map(\.value), ["0", "250 credits · $10.00"])

        var claude = AccountDetails()
        claude.claudeUsageCredits = .off
        claude.cloudCredits = .init(remaining: 95.089746, limit: 100, expiresAt: nil)
        XCTAssertEqual(ExpandedView.detailRows(for: .claude, details: claude).map(\.value), ["Off", "$95.09 / $100.00"])
        XCTAssertEqual(ExpandedView.detailRows(for: .claude, details: AccountDetails()), [], "missing values hide rows")
    }

    func testCodexShowsRemainingAndClaudeShowsUsed() {
        let now = Date(timeIntervalSince1970: 0)
        let window = LimitWindow(usedPercent: 3, resetsAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(window.shownText(for: .codex, at: now), "97%")
        XCTAssertEqual(window.shownText(for: .claude, at: now), "3%")
        XCTAssertEqual(LimitWindow(usedPercent: 120, resetsAt: nil).shownPercent(for: .codex), 0, "over the limit")
        let expired = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(window.shownText(for: .codex, at: expired), "100%", "a reset window is full again")
    }

    func testExpiredWindowDisplaysZero() {
        let window = LimitWindow(usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(window.displayPercent(at: Date(timeIntervalSince1970: 999)), 80)
        XCTAssertEqual(window.displayPercent(at: Date(timeIntervalSince1970: 1000)), 0)
        XCTAssertEqual(window.resetText(at: Date(timeIntervalSince1970: 2000)), "window reset")
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

    func testOnlyApplicationsFolderCountsAsStableLocation() {
        func configurator(_ path: String) -> ClaudeStatusLineConfigurator {
            ClaudeStatusLineConfigurator(settingsFile: URL(fileURLWithPath: "/dev/null"), executableURL: URL(fileURLWithPath: path))
        }
        XCTAssertTrue(configurator("/Applications/Limita.app/Contents/MacOS/Limita").isRunningFromStableLocation)
        XCTAssertTrue(configurator(NSHomeDirectory() + "/Applications/Limita.app/Contents/MacOS/Limita").isRunningFromStableLocation)
        XCTAssertFalse(configurator("/private/tmp/dd/Build/Products/Debug/Limita.app/Contents/MacOS/Limita").isRunningFromStableLocation)
        XCTAssertFalse(configurator(NSHomeDirectory() + "/Downloads/Limita.app/Contents/MacOS/Limita").isRunningFromStableLocation)
    }

    func testRepairDoesNotPointHookAtUnstableBuild() throws {
        let settings = try temporaryDirectory().appendingPathComponent("settings.json")
        let old = ClaudeStatusLineConfigurator(settingsFile: settings, executableURL: URL(fileURLWithPath: "/old/Limita"))
        let build = ClaudeStatusLineConfigurator(settingsFile: settings, executableURL: URL(fileURLWithPath: "/tmp/dd/Limita"))
        XCTAssertEqual(try old.install(), .installed)
        XCTAssertFalse(try build.repairIfNeeded())
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

    // MARK: - Connected services

    func testServiceSettingsDetectOnceThenKeepChoice() {
        let defaults = UserDefaults(suiteName: "limita-tests-\(UUID().uuidString)")!
        let settings = ServiceSettings(defaults: defaults)
        var detections = 0
        XCTAssertEqual(settings.load { detections += 1; return [.codex] }, [.codex])
        XCTAssertEqual(settings.load { detections += 1; return [.claude, .codex] }, [.codex], "detection runs only once")
        XCTAssertEqual(detections, 1)

        settings.save([])
        XCTAssertEqual(settings.load { [.claude] }, [], "an empty choice is kept, not re-detected")
    }

    func testDetectInstalledUsesCLIOrConfigFolder() throws {
        let home = try temporaryDirectory()
        XCTAssertEqual(ServiceSettings.detectInstalled(home: home, findCLI: { _ in nil }), [])

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        XCTAssertEqual(ServiceSettings.detectInstalled(home: home, findCLI: { _ in nil }), [.claude])

        let withCodex = ServiceSettings.detectInstalled(home: home, findCLI: { $0 == "codex" ? URL(fileURLWithPath: "/x/codex") : nil })
        XCTAssertEqual(withCodex, [.claude, .codex])
    }

    @MainActor
    func testConnectAndDisconnectPersistAndKeepClaudeFirst() throws {
        let root = try temporaryDirectory()
        let suite = "limita-tests-\(UUID().uuidString)"
        let settingsFile = root.appendingPathComponent("settings.json")
        func makeStore() -> LimitsStore {
            var codex = CodexLiveClient()
            codex.findExecutable = { nil }
            var claude = ClaudeLiveClient()
            claude.accessToken = { _ in throw ClaudeLiveClient.FetchError(message: "no token in tests") }
            return LimitsStore(
                codexReader: CodexLimitsReader(sessionsDirectory: root, archivedSessionsDirectory: root),
                claudeReader: ClaudeLimitsReader(cacheFile: root.appendingPathComponent("claude.json")),
                codexLive: codex,
                claudeLive: claude,
                configurator: ClaudeStatusLineConfigurator(
                    settingsFile: settingsFile,
                    executableURL: URL(fileURLWithPath: "/Applications/Limita.app/Contents/MacOS/Limita")
                ),
                settings: ServiceSettings(defaults: UserDefaults(suiteName: suite)!),
                detectInstalled: { [] }
            )
        }

        let store = makeStore()
        XCTAssertEqual(store.enabledServices, [])

        store.connect(.codex)
        store.connect(.claude)
        XCTAssertEqual(store.enabledServices, [.claude, .codex], "Claude is always first")
        XCTAssertEqual(try ClaudeStatusLineConfigurator(settingsFile: settingsFile, executableURL: URL(fileURLWithPath: "/x")).status(),
                       .installed(executablePath: "/Applications/Limita.app/Contents/MacOS/Limita", wrapped: nil),
                       "connecting Claude installs the status-line hook")
        XCTAssertEqual(makeStore().enabledServices, [.claude, .codex], "the choice survives a relaunch")

        store.disconnect(.claude)
        XCTAssertEqual(store.enabledServices, [.codex])
        XCTAssertEqual(try ClaudeStatusLineConfigurator(settingsFile: settingsFile, executableURL: URL(fileURLWithPath: "/x")).status(),
                       .notConfigured, "disconnecting Claude removes the hook")
        XCTAssertEqual(makeStore().enabledServices, [.codex])
    }

    func testUpdatedTextNeverSaysInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ExpandedView.updatedText(now.addingTimeInterval(0.4), now: now), "just now")
        XCTAssertEqual(ExpandedView.updatedText(now.addingTimeInterval(-3), now: now), "just now")
        XCTAssertEqual(ExpandedView.updatedText(now.addingTimeInterval(-7200), now: now), "2 hours ago")
    }

    @MainActor
    func testMenuTitles() {
        XCTAssertEqual(AppDelegate.menuTitle(for: .claude, connected: true), "Disconnect Claude Code")
        XCTAssertEqual(AppDelegate.menuTitle(for: .codex, connected: false), "Connect Codex")
    }

    @MainActor
    func testPanelSizesFollowConnectedServices() {
        XCTAssertEqual(BezelPanelController.expandedSize(services: 2).width, 2 * BezelPanelController.expandedSize(services: 1).width)
        XCTAssertLessThan(BezelPanelController.pillSize(services: 1).width, BezelPanelController.pillSize(services: 2).width)
        XCTAssertGreaterThan(BezelPanelController.expandedSize(services: 0).width, 0)
    }

    // MARK: - Claude login errors

    func testKeychainStatusesMapToSpecificMessages() {
        XCTAssertNil(ClaudeLiveClient.keychainError(errSecItemNotFound), "missing item means not signed in, handled elsewhere")
        XCTAssertTrue(ClaudeLiveClient.keychainError(errSecUserCanceled)?.message.contains("denied") ?? false)
        XCTAssertTrue(ClaudeLiveClient.keychainError(-99)?.message.contains("-99") ?? false)
    }

    func testExpiredTokenSaysWhen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":\#((now.timeIntervalSince1970 - 3 * 3600) * 1000)}}"#
        XCTAssertThrowsError(try ClaudeLiveClient.accessToken(fromCredentials: Data(expired.utf8), now: now)) { error in
            XCTAssertTrue(error.localizedDescription.contains("3 hours ago"), error.localizedDescription)
        }
        let valid = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":\#((now.timeIntervalSince1970 + 60) * 1000)}}"#
        XCTAssertEqual(try ClaudeLiveClient.accessToken(fromCredentials: Data(valid.utf8), now: now), "t")
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
