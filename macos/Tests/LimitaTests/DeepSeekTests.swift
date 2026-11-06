import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Limita

final class DeepSeekTests: XCTestCase {
    // MARK: - Balance response

    func testBalanceResponseIsParsedFromStrings() throws {
        let json = """
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "110.00",
        "granted_balance": "10.00", "topped_up_balance": "100.00"}]}
        """
        let balance = try DeepSeekClient.balance(fromResponse: Data(json.utf8))
        XCTAssertEqual(balance.currency, "CNY")
        XCTAssertEqual(balance.total, 110)
        XCTAssertEqual(balance.granted, 10)
        XCTAssertEqual(balance.toppedUp, 100)
        XCTAssertTrue(balance.isAvailable)
        XCTAssertEqual(balance.others, [])
    }

    func testTheCurrencyWithTheMostMoneyIsTheMainOne() throws {
        let json = """
        {"is_available": false, "balance_infos": [
          {"currency": "CNY", "total_balance": 3, "granted_balance": 3, "topped_up_balance": 0},
          {"currency": "USD", "total_balance": "12.50", "granted_balance": "0", "topped_up_balance": "12.50"}]}
        """
        let balance = try DeepSeekClient.balance(fromResponse: Data(json.utf8))
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.total, 12.5)
        XCTAssertFalse(balance.isAvailable)
        XCTAssertEqual(balance.others, [Balance.Amount(currency: "CNY", total: 3)])
    }

    func testAnEmptyOrBrokenBalanceResponse() throws {
        let empty = try DeepSeekClient.balance(fromResponse: Data(#"{"is_available": true, "balance_infos": []}"#.utf8))
        XCTAssertEqual(empty.total, 0)
        XCTAssertThrowsError(try DeepSeekClient.balance(fromResponse: Data("<html>".utf8)))
    }

    func testBalanceFormatting() {
        XCTAssertEqual(Balance.format(110, currency: "CNY"), "¥110.00")
        XCTAssertEqual(Balance.format(4.2, currency: "USD"), "$4.20")
        XCTAssertEqual(Balance.format(1234.5, currency: "USD"), "$1,234.50")
        XCTAssertEqual(Balance.format(3, currency: "EUR"), "EUR 3.00")
    }

    // MARK: - Level and the dashboard

    func testBalanceLevelFollowsTheThresholdOrTheLastTopUp() {
        var balance = Balance(currency: "CNY", total: 8, granted: 0, toppedUp: 8, isAvailable: true)
        XCTAssertEqual(balance.level, .normal, "nothing to compare with")
        balance.fullScale = 100
        XCTAssertEqual(balance.level, .critical, "8 % of the last top-up left")
        balance.fullScale = 20
        XCTAssertEqual(balance.level, .normal, "40 % left")
        balance.lowThreshold = 5
        XCTAssertEqual(balance.level, .warning, "within twice the threshold")
        balance.lowThreshold = 8
        XCTAssertEqual(balance.level, .critical, "at the threshold")
        XCTAssertTrue(balance.isLow)
        balance.lowThreshold = 1
        XCTAssertEqual(balance.level, .normal)
        let rejected = Balance(currency: "CNY", total: 50, granted: 0, toppedUp: 50, isAvailable: false)
        XCTAssertEqual(rejected.level, .critical, "calls are rejected")
    }

    func testBalanceStateDrivesTheDotAndThePill() {
        var balance = Balance(currency: "CNY", total: 86.4, granted: 10, toppedUp: 76.4, isAvailable: true)
        balance.fullScale = 100
        let state = ServiceState.fresh(LimitSnapshot(balance: balance, capturedAt: Date()))
        XCTAssertEqual(state.level(), .normal)
        XCTAssertFalse(state.snapshot!.isEmpty)
        XCTAssertEqual(MiniPillView.label(for: .deepseek, state: state, now: Date()), "¥86.40")
        XCTAssertEqual(MiniPillView.label(for: .deepseek, state: .unavailable(reason: "x"), now: Date()), "—")
    }

    func testBalanceMeterAndTiles() {
        var balance = Balance(currency: "CNY", total: 30, granted: 5, toppedUp: 25, isAvailable: true)
        balance.fullScale = 120
        balance.dailyBurn = 3
        balance.spentToday = 1.5
        balance.spentThisMonth = 40
        let meter = ExpandedView.balanceMeter(balance)
        XCTAssertEqual(meter.value, "25%")
        XCTAssertEqual(meter.amount, "¥30.00 OF ¥120.00 LEFT")
        XCTAssertEqual(meter.caption, "LASTS ~10 DAYS AT THIS PACE")

        let rows = ExpandedView.balanceRows(balance)
        XCTAssertEqual(rows.map(\.label), ["SPENT TODAY", "THIS MONTH", "PER DAY", "ALERT BELOW", "TOPPED UP", "GRANTED"])
        XCTAssertEqual(rows[0].value, "¥1.50")
        XCTAssertEqual(rows[3].value, "Off")

        balance.dailyBurn = nil
        XCTAssertEqual(ExpandedView.balanceRows(balance)[2].value, "Collecting data")
        balance.lowThreshold = 50
        XCTAssertEqual(ExpandedView.balanceMeter(balance).caption, "BELOW YOUR ALERT")
        let rejected = Balance(currency: "CNY", total: 0, granted: 0, toppedUp: 0, isAvailable: false)
        XCTAssertEqual(ExpandedView.balanceMeter(rejected).caption, "CALLS REJECTED · TOP UP")
        XCTAssertEqual(ExpandedView.daysText(0.25), "6 HOURS")
    }

    // MARK: - Ledger

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2030-01-15 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_894_708_800)

    private func sample(_ hoursBeforeNoon: Double, _ total: Double) -> BalanceLedger.Sample {
        BalanceLedger.Sample(date: noon.addingTimeInterval(-hoursBeforeNoon * 3600), total: total)
    }

    func testLedgerCountsDropsAsSpendingAndRisesAsTopUps() {
        let samples = [
            sample(30 * 24, 50),  // Dec 16
            sample(10 * 24, 40),  // Jan 5: spent 10 this month
            sample(5 * 24, 140),  // Jan 10: topped up
            sample(13, 130),      // Jan 14, 23:00: spent 10
            sample(2, 125),       // today: spent 5
            sample(1, 123),       // today: spent 2
        ]
        let summary = BalanceLedger.summarize(samples, now: noon, calendar: utc)
        XCTAssertEqual(summary.spentToday, 7)
        XCTAssertEqual(summary.spentThisMonth, 27)
        XCTAssertEqual(summary.fullScale, 140, "the balance right after the last top-up")
        XCTAssertEqual(summary.dailyBurn!, 17.0 / 7, accuracy: 0.0001, "spent in the last week over 7 days")
    }

    func testLedgerNeedsADayBeforeItShowsThePace() {
        let young = BalanceLedger.summarize([sample(5, 20), sample(1, 18)], now: noon, calendar: utc)
        XCTAssertNil(young.dailyBurn)
        XCTAssertEqual(young.spentToday, 2)
        XCTAssertEqual(young.fullScale, 20, "without a top-up, the highest balance seen")

        let twoDays = BalanceLedger.summarize([sample(48, 20), sample(1, 16)], now: noon, calendar: utc)
        XCTAssertEqual(twoDays.dailyBurn!, 2, accuracy: 0.0001)
    }

    func testLedgerRecordsOnlyChangesAndStartsOverForAnotherCurrency() {
        var ledger = BalanceLedger(url: nil)
        _ = ledger.record(total: 10, currency: "CNY", at: noon.addingTimeInterval(-120), calendar: utc)
        _ = ledger.record(total: 10, currency: "CNY", at: noon.addingTimeInterval(-60), calendar: utc)
        let summary = ledger.record(total: 9, currency: "CNY", at: noon, calendar: utc)
        XCTAssertEqual(ledger.samples.count, 2, "an unchanged balance is not stored again")
        XCTAssertEqual(summary.spentToday, 1)
        _ = ledger.record(total: 3, currency: "USD", at: noon.addingTimeInterval(60), calendar: utc)
        XCTAssertEqual(ledger.samples.map(\.total), [3])
        _ = ledger.record(total: 2, currency: "USD", at: noon, calendar: utc)
        XCTAssertEqual(ledger.samples.map(\.total), [3], "an older reading is ignored")
    }

    func testLedgerPersistsAndClears() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var ledger = BalanceLedger(url: url)
        _ = ledger.record(total: 10, currency: "CNY", at: noon, calendar: utc)
        ledger.alertedLow = true
        let reloaded = BalanceLedger(url: url)
        XCTAssertEqual(reloaded.samples.map(\.total), [10])
        XCTAssertTrue(reloaded.alertedLow)
        ledger.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(BalanceLedger(url: url).samples, [])
    }

    func testLedgerCompactsOldSamplesToOnePerHour() {
        let old = (0..<6).map { BalanceLedger.Sample(date: noon.addingTimeInterval(-48 * 3600 + Double($0) * 600), total: Double(100 - $0)) }
        let recent = [sample(1, 50), sample(0.5, 49)]
        let ancient = BalanceLedger.Sample(date: noon.addingTimeInterval(-100 * 24 * 3600), total: 500)
        let compacted = BalanceLedger.compacted([ancient] + old + recent, now: noon)
        XCTAssertEqual(compacted.map(\.total), [95, 50, 49], "the hour's last sample, nothing older than 90 days")
    }

    // MARK: - Update check without GitHub's API

    private func response(_ url: String, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testTheLatestReleaseIsFoundFromTheRedirect() async throws {
        let release = try await AppUpdater.latestReleaseFromWeb(head: { url in
            if url == AppUpdater.latestPage {
                return self.response("https://github.com/realfamousbae/limita/releases/tag/v0.24.0", 200)
            }
            XCTAssertEqual(url.absoluteString,
                           "https://github.com/realfamousbae/limita/releases/download/v0.24.0/Limita-0.24.0.dmg.sig")
            return self.response(url.absoluteString, 200)
        })
        XCTAssertEqual(release?.version, "0.24.0")
        XCTAssertEqual(release?.dmg.absoluteString,
                       "https://github.com/realfamousbae/limita/releases/download/v0.24.0/Limita-0.24.0.dmg")
        XCTAssertEqual(release?.page.absoluteString, "https://github.com/realfamousbae/limita/releases/tag/v0.24.0")
    }

    func testAReleaseWithoutTheSignatureOrWithoutReleasesIsNotOffered() async throws {
        let unsigned = try await AppUpdater.latestReleaseFromWeb(head: { url in
            url == AppUpdater.latestPage
                ? self.response("https://github.com/realfamousbae/limita/releases/tag/v0.25.0", 200)
                : self.response(url.absoluteString, 404)
        })
        XCTAssertNil(unsigned)
        let none = try await AppUpdater.latestReleaseFromWeb(head: { _ in
            self.response("https://github.com/realfamousbae/limita/releases", 200)
        })
        XCTAssertNil(none, "no releases: the redirect does not reach a tag")
    }

    func testARateLimitSaysSo() async {
        do {
            _ = try await AppUpdater.latestReleaseFromWeb(head: { url in self.response(url.absoluteString, 429) })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "GitHub is limiting requests from this network (429); Limita tries again later")
        }
        XCTAssertEqual(AppUpdater.tag(fromReleasePage: URL(string: "https://github.com/o/r/releases/tag/v1.2.3")!), "v1.2.3")
        XCTAssertNil(AppUpdater.tag(fromReleasePage: URL(string: "https://github.com/o/r/releases")!))
    }

    // MARK: - Keychain

    /// The real Keychain, with an item of its own that the test removes. The same process
    /// creates and reads it, so macOS asks nothing.
    func testKeychainStoreSavesReplacesAndDeletes() throws {
        let store = KeychainStore(service: "com.limita.tests.\(UUID().uuidString)")
        addTeardownBlock { try? store.delete() }
        XCTAssertNil(try store.read())
        try store.save("sk-first")
        XCTAssertEqual(try store.read(), "sk-first")
        try store.save("sk-second")
        XCTAssertEqual(try store.read(), "sk-second", "a second save replaces the item")
        try store.delete()
        XCTAssertNil(try store.read())
        XCTAssertNoThrow(try store.delete(), "deleting nothing is fine")
    }

    // MARK: - Store

    private final class MemorySecret: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ value: String? = nil) { self.value = value }
        func read() throws -> String? { lock.withLock { value } }
        func save(_ value: String) throws { lock.withLock { self.value = value } }
        func delete() throws { lock.withLock { value = nil } }
    }

    /// Answers the balance request with `total` CNY, or `status` alone.
    private final class FakeDeepSeek: @unchecked Sendable {
        private let lock = NSLock()
        var total: Double = 50
        var available = true
        var status = 200
        private(set) var keys: [String] = []

        var client: DeepSeekClient {
            var client = DeepSeekClient(apiKey: { nil })
            client.load = { [self] request in
                let (status, body) = lock.withLock { () -> (Int, String) in
                    keys.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                    return (self.status, """
                    {"is_available": \(available), "balance_infos": [{"currency": "CNY",
                    "total_balance": "\(total)", "granted_balance": "0", "topped_up_balance": "\(total)"}]}
                    """)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
            return client
        }
    }

    @MainActor
    private func makeStore(fake: FakeDeepSeek, secret: MemorySecret, suite: String = "limita-tests-\(UUID().uuidString)") -> LimitsStore {
        let defaults = UserDefaults(suiteName: suite)!
        return LimitsStore(
            deepseekLive: fake.client,
            deepseekKey: secret,
            ledger: BalanceLedger(url: nil),
            // Not the user's Claude Code settings: a hook there would connect Claude.
            configurator: ClaudeStatusLineConfigurator(
                settingsFile: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json"),
                executableURL: URL(fileURLWithPath: "/Applications/Limita.app/Contents/MacOS/Limita")
            ),
            settings: ServiceSettings(defaults: defaults),
            resets: ResetWatcher(defaults: defaults, feedURL: { _ in nil }),
            detectInstalled: { [] }
        )
    }

    @MainActor
    func testARejectedKeyIsNeitherStoredNorConnected() async {
        let fake = FakeDeepSeek()
        fake.status = 401
        let secret = MemorySecret()
        let store = makeStore(fake: fake, secret: secret)
        let error = await store.connectDeepSeek(apiKey: "  sk-wrong ")
        XCTAssertEqual(error, "DeepSeek rejected the API key (401) — check it in Settings")
        XCTAssertEqual(fake.keys, ["Bearer sk-wrong"], "the key is trimmed")
        XCTAssertNil(try secret.read())
        XCTAssertFalse(store.isEnabled(.deepseek))
        let empty = await store.connectDeepSeek(apiKey: " ")
        XCTAssertEqual(empty, "Enter a DeepSeek API key")
    }

    @MainActor
    func testConnectingDeepSeekStoresTheKeyAndShowsTheBalance() async throws {
        let fake = FakeDeepSeek()
        let secret = MemorySecret()
        let store = makeStore(fake: fake, secret: secret)
        let error = await store.connectDeepSeek(apiKey: "sk-0123456789abcdef")
        XCTAssertNil(error)
        XCTAssertEqual(try secret.read(), "sk-0123456789abcdef")
        XCTAssertEqual(store.enabledServices, [.deepseek])
        XCTAssertEqual(store.state(for: .deepseek).snapshot?.balance?.total, 50)
        XCTAssertEqual(store.deepseekKeyHint(), "sk-…cdef")

        store.disconnect(.deepseek)
        XCTAssertNil(try secret.read(), "disconnecting removes the key")
        XCTAssertEqual(store.enabledServices, [])
    }

    @MainActor
    func testDeepSeekCannotConnectWithoutAKey() {
        let store = makeStore(fake: FakeDeepSeek(), secret: MemorySecret())
        store.connect(.deepseek)
        XCTAssertFalse(store.isEnabled(.deepseek))
        XCTAssertEqual(store.setupMessage?.text, "Add your DeepSeek API key in Settings")
    }

    @MainActor
    func testLowBalanceIsAnnouncedOncePerDrop() async {
        let fake = FakeDeepSeek()
        let store = makeStore(fake: fake, secret: MemorySecret())
        var alerts: [String] = []
        store.alert = { _, title, _ in alerts.append(title) }
        store.lowBalanceThreshold = 10

        fake.total = 50
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        XCTAssertEqual(alerts, [])

        fake.total = 8
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        XCTAssertEqual(alerts, ["DeepSeek balance is low"], "once, not at every reading")
        XCTAssertEqual(store.state(for: .deepseek).level(), .critical)

        fake.total = 80
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        fake.total = 5
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        XCTAssertEqual(alerts.count, 2, "a top-up arms it again")

        fake.available = false
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        XCTAssertEqual(alerts.last, "DeepSeek balance ran out")

        store.balanceAlertsEnabled = false
        fake.available = true
        fake.total = 90
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        fake.total = 1
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        XCTAssertEqual(alerts.count, 3, "alerts turned off")
    }

    @MainActor
    func testAChangedThresholdShowsAtOnce() async {
        let fake = FakeDeepSeek()
        fake.total = 12
        let store = makeStore(fake: fake, secret: MemorySecret())
        _ = await store.connectDeepSeek(apiKey: "sk-key")
        XCTAssertEqual(store.state(for: .deepseek).level(), .normal)
        store.lowBalanceThreshold = 20
        XCTAssertEqual(store.state(for: .deepseek).snapshot?.balance?.lowThreshold, 20)
        XCTAssertEqual(store.state(for: .deepseek).level(), .critical)
        store.lowBalanceThreshold = -1
        XCTAssertNil(store.lowBalanceThreshold, "zero or less turns it off")
    }

    @MainActor
    func testLiveIntervalsAreSavedAndHaveAFloor() {
        let suite = "limita-tests-\(UUID().uuidString)"
        let store = makeStore(fake: FakeDeepSeek(), secret: MemorySecret(), suite: suite)
        XCTAssertEqual(store.liveInterval(for: .claude), 180)
        XCTAssertEqual(store.liveInterval(for: .deepseek), 300)
        store.setLiveInterval(600, for: .claude)
        store.setLiveInterval(10, for: .codex)
        XCTAssertEqual(store.liveInterval(for: .codex), 60, "never under a minute")
        let reloaded = makeStore(fake: FakeDeepSeek(), secret: MemorySecret(), suite: suite)
        XCTAssertEqual(reloaded.liveInterval(for: .claude), 600)
        reloaded.setLiveInterval(180, for: .claude)
        XCTAssertNil(ServiceSettings(defaults: UserDefaults(suiteName: suite)!).liveIntervals[.claude], "the default is not stored")
        XCTAssertEqual(store.staleAfter(for: .deepseek), 30 * 60)
        store.setLiveInterval(30 * 60, for: .deepseek)
        XCTAssertEqual(store.staleAfter(for: .deepseek), 61 * 60, "two missed fetches")
    }

    func testKeyHint() {
        XCTAssertEqual(LimitsStore.keyHint("sk-0123456789abcdef"), "sk-…cdef")
        XCTAssertEqual(LimitsStore.keyHint("abcdefghijkl"), "…ijkl")
        XCTAssertEqual(LimitsStore.keyHint("short"), "•••••")
    }

    func testDeepSeekIsNeverDetectedAndHasNoTrackerOrPeakHours() {
        XCTAssertNil(ResetFeed.url(for: .deepseek))
        XCTAssertNil(Service.deepseek.primeTime)
        XCTAssertEqual(Service.deepseek.kind, .balance)
        XCTAssertEqual(Service.allCases, [.claude, .codex, .deepseek], "display order")
    }

    func testPeakHoursNameTheServicesWhenDeepSeekIsConnected() {
        let both = PrimeTimeNotice(active: [.claude, .codex], connected: [.claude, .codex, .deepseek])
        XCTAssertEqual(both?.strong, "CLAUDE & CODEX")
        XCTAssertEqual(both?.firstLine, "CLAUDE & CODEX PEAK HOURS")
        XCTAssertEqual(PrimeTimeNotice(active: [.claude, .codex], connected: [.claude, .codex])?.firstLine,
                       "PEAK HOURS FOR ALL PROVIDERS")
        XCTAssertEqual(PrimeTimeNotice(active: [.codex], connected: [.codex, .deepseek])?.strong, "CODEX")
        XCTAssertEqual(PrimeTimeNotice(active: [.codex], connected: [.codex])?.firstLine, "CODEX PEAK HOURS")
    }

    func testTerminalSnapshotCarriesTheBalance() throws {
        let now = Date(timeIntervalSince1970: 1_893_456_000)
        var balance = Balance(currency: "CNY", total: 4.5, granted: 0, toppedUp: 4.5, isAvailable: true)
        balance.lowThreshold = 5
        let snapshot = TerminalSnapshot(
            services: [.deepseek], states: { _ in .fresh(LimitSnapshot(balance: balance, capturedAt: now)) },
            primeTime: [], staleAfter: { _ in 1800 }
        )
        let json = try JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any]
        let entry = try XCTUnwrap((json?["services"] as? [[String: Any]])?.first)
        let money = try XCTUnwrap(entry["balance"] as? [String: Any])
        XCTAssertEqual(money["text"] as? String, "¥4.50")
        XCTAssertEqual(money["level"] as? String, "critical")
        XCTAssertEqual(entry["staleAfter"] as? Double, 1800)
    }

    // MARK: - Settings

    func testBalanceSettingsAreSaved() {
        let settings = ServiceSettings(defaults: UserDefaults(suiteName: "limita-tests-\(UUID().uuidString)")!)
        XCTAssertNil(settings.lowBalanceThreshold)
        XCTAssertTrue(settings.balanceAlertsEnabled)
        settings.lowBalanceThreshold = 5
        settings.balanceAlertsEnabled = false
        XCTAssertEqual(settings.lowBalanceThreshold, 5)
        XCTAssertFalse(settings.balanceAlertsEnabled)
        settings.lowBalanceThreshold = 0
        XCTAssertNil(settings.lowBalanceThreshold)
    }

    // MARK: - Shortcuts

    func testHotKeyBindingText() {
        let binding = HotKeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: [.control, .option, .capsLock], character: "L")
        XCTAssertEqual(binding.displayText, "⌃⌥L")
        XCTAssertEqual(binding.keyEquivalent, "l")
        XCTAssertEqual(binding.modifierFlags, [.control, .option], "only ⌃⌥⇧⌘ are kept")
        XCTAssertTrue(binding.isValid)
        let function = HotKeyBinding(keyCode: UInt32(kVK_F5), modifiers: [.command, .shift], character: "")
        XCTAssertEqual(function.displayText, "⇧⌘F5")
        XCTAssertNil(function.keyEquivalent)
        XCTAssertFalse(HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: [.shift], character: "a").isValid)
        XCTAssertEqual(HotKeyAction.dashboard.defaultBinding.displayText, "⌃⌥L")
    }

    @MainActor
    func testHotKeysAreSavedTurnedOffAndReset() {
        let suite = "limita-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = HotKeyCenter(defaults: defaults)
        XCTAssertEqual(center.binding(for: .hoverPill), HotKeyAction.hoverPill.defaultBinding)
        XCTAssertNil(defaults.data(forKey: HotKeyCenter.storageKey), "defaults are not stored")

        let custom = HotKeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: [.command, .option], character: "k")
        center.set(custom, for: .dashboard)
        center.set(nil, for: .floatingWindow)
        let reloaded = HotKeyCenter(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .dashboard), custom)
        XCTAssertNil(reloaded.binding(for: .floatingWindow), "turned off stays off")
        XCTAssertEqual(reloaded.binding(for: .hoverPill), HotKeyAction.hoverPill.defaultBinding)

        reloaded.set(custom, for: .hoverPill)
        XCTAssertNil(reloaded.binding(for: .dashboard), "one shortcut does one thing")

        reloaded.reset(.dashboard)
        reloaded.reset(.hoverPill)
        reloaded.reset(.floatingWindow)
        XCTAssertNil(defaults.data(forKey: HotKeyCenter.storageKey))
    }
}
