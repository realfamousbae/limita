import Foundation
import Observation
import os

@Observable
@MainActor
final class LimitsStore {
    /// Local sources (Codex session logs, Claude status-line cache) are cheap and read
    /// every minute; each service's network API is asked every `liveInterval(for:)`
    /// or on manual refresh.
    static let localInterval: TimeInterval = 60

    /// How often a service's network API is asked unless the user chose otherwise.
    static func defaultLiveInterval(for service: Service) -> TimeInterval {
        switch service {
        case .claude: 3 * 60
        case .codex, .deepseek: 5 * 60
        }
    }

    /// The intervals Settings offers. Nothing under a minute: local reads tick once a
    /// minute anyway, and a busier poll only earns 429s.
    static let liveIntervalChoices: [TimeInterval] = [1, 2, 3, 5, 10, 15, 30].map { $0 * 60 }

    /// How often `service`'s network API is asked.
    func liveInterval(for service: Service) -> TimeInterval {
        max(liveIntervals[service] ?? Self.defaultLiveInterval(for: service), Self.localInterval)
    }

    func setLiveInterval(_ interval: TimeInterval, for service: Service) {
        var intervals = liveIntervals
        intervals[service] = interval == Self.defaultLiveInterval(for: service) ? nil : max(interval, Self.localInterval)
        liveIntervals = intervals
        settings.liveIntervals = intervals
    }

    /// Age after which a service's data reads as stale. A service with only a network
    /// source allows two missed fetches at the chosen interval.
    func staleAfter(for service: Service) -> TimeInterval {
        switch service {
        case .claude: ClaudeLimitsReader.staleAfter
        case .codex: CodexLimitsReader.staleAfter
        case .deepseek: max(30 * 60, 2 * liveInterval(for: service) + Self.localInterval)
        }
    }

    /// Services the user tracks, in display order. Only these are read, fetched and shown.
    private(set) var enabledServices: [Service]
    private(set) var states: [Service: ServiceState] = [:]
    /// Last network error per service; cleared by the next successful fetch.
    private(set) var liveErrors: [Service: String] = [:]
    /// Balances and extras from the last successful network read.
    private(set) var details: [Service: AccountDetails] = [:]
    private(set) var isRefreshing = false
    /// Enabled services whose peak hours are on now, in display order.
    private(set) var primeTimeServices: [Service] = []
    /// What the prime-time badge says, `nil` while no badge shows.
    var primeTimeNotice: PrimeTimeNotice? {
        PrimeTimeNotice(active: primeTimeServices, connected: enabledServices)
    }
    /// Result of the last connect/disconnect, for the service it concerns.
    var setupMessage: (service: Service, text: String)?
    /// Intervals the user changed in Settings.
    private(set) var liveIntervals: [Service: TimeInterval]
    /// DeepSeek balance at or below which the dot turns red and a notification fires.
    var lowBalanceThreshold: Double? {
        didSet {
            guard lowBalanceThreshold != oldValue else { return }
            settings.lowBalanceThreshold = lowBalanceThreshold
            lowBalanceThreshold = settings.lowBalanceThreshold
            reapplyBalanceThreshold()
        }
    }
    /// Whether a low or exhausted DeepSeek balance is announced.
    var balanceAlertsEnabled: Bool {
        didSet { settings.balanceAlertsEnabled = balanceAlertsEnabled }
    }
    /// Whether the menu-bar icon is shown. Not saved: every launch starts with the icon,
    /// so its menu (Connect, Quit) is always reachable after a restart.
    var showsMenuBarIcon = true {
        didSet { onMenuBarIconChange?(showsMenuBarIcon) }
    }
    @ObservationIgnored var onMenuBarIconChange: ((Bool) -> Void)?
    /// Opens the Settings window, on a tab or where it was left. Set by the app delegate.
    @ObservationIgnored var onOpenSettings: ((SettingsTab?) -> Void)?
    /// Whether resting the cursor at the screen edge shows the pill. While off, nothing
    /// watches the mouse. Saved, unlike the icon: the dashboard stays reachable by the
    /// menu-bar icon and the shortcut either way.
    var hoverEnabled: Bool {
        didSet {
            guard hoverEnabled != oldValue else { return }
            settings.hoverEnabled = hoverEnabled
            onHoverEnabledChange?(hoverEnabled)
        }
    }
    @ObservationIgnored var onHoverEnabledChange: ((Bool) -> Void)?
    /// Whether the dashboard floats where the user put it: it stays open until closed by
    /// the shortcut, the menu-bar icon or this toggle, on every Space. Saved with its position.
    var floatingEnabled: Bool {
        didSet {
            guard floatingEnabled != oldValue else { return }
            settings.floatingEnabled = floatingEnabled
            onFloatingChange?(floatingEnabled)
        }
    }
    @ObservationIgnored var onFloatingChange: ((Bool) -> Void)?
    /// Where the floating dashboard was last left, as its top-left corner.
    var floatingOrigin: CGPoint? {
        get { settings.floatingOrigin }
        set { settings.floatingOrigin = newValue }
    }
    /// Meters folded into a capsule under the others. Saved, like the activity panel.
    private(set) var collapsedMeters: Set<String> {
        didSet {
            guard collapsedMeters != oldValue else { return }
            settings.collapsedMeters = collapsedMeters
        }
    }
    /// Tokens per day for the activity panel under the dashboard.
    let activity: ActivityStore
    /// A newer Limita, when GitHub has one; the dashboard shows an install button for it.
    let updater: AppUpdater
    /// Limit resets from the public trackers and from the user's own numbers.
    let resets: ResetWatcher

    /// Newest snapshot fetched over the network per service.
    @ObservationIgnored private var liveSnapshots: [Service: LimitSnapshot] = [:]
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var primeTimeTimer: Timer?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastLiveAttempt: [Service: Date] = [:]
    /// After a 429 the service's network API is left alone until then, even by Refresh.
    @ObservationIgnored private var livePausedUntil: [Service: Date] = [:]
    /// 429s in a row per service; each one doubles the pause.
    @ObservationIgnored private var rateLimitStreak: [Service: Int] = [:]
    @ObservationIgnored private var pendingLive = false
    /// Last snapshot written for the iTerm2 script, so an unchanged one is not rewritten.
    @ObservationIgnored private var writtenSnapshot: TerminalSnapshot?
    @ObservationIgnored private let codexReader: CodexLimitsReader
    @ObservationIgnored private let claudeReader: ClaudeLimitsReader
    @ObservationIgnored private let codexLive: CodexLiveClient
    @ObservationIgnored private let claudeLive: ClaudeLiveClient
    @ObservationIgnored private let deepseekLive: DeepSeekClient
    @ObservationIgnored private let deepseekKey: any SecretStoring
    @ObservationIgnored private var ledger: BalanceLedger
    /// Shows a notification: id, title, body. Injectable so tests can record them.
    @ObservationIgnored var alert: (String, String, String) -> Void = { id, title, body in
        SystemResetNotifier.shared.notify(id: id, title: title, body: body)
    }
    @ObservationIgnored private let configurator: ClaudeStatusLineConfigurator
    @ObservationIgnored private let settings: ServiceSettings
    @ObservationIgnored private let log = Logger(subsystem: "com.limita.app", category: "refresh")

    init(
        codexReader: CodexLimitsReader = CodexLimitsReader(),
        claudeReader: ClaudeLimitsReader = ClaudeLimitsReader(),
        codexLive: CodexLiveClient = CodexLiveClient(),
        claudeLive: ClaudeLiveClient = ClaudeLiveClient(),
        deepseekLive: DeepSeekClient? = nil,
        deepseekKey: any SecretStoring = KeychainStore.deepseek,
        ledger: BalanceLedger = BalanceLedger(),
        configurator: ClaudeStatusLineConfigurator = ClaudeStatusLineConfigurator(),
        settings: ServiceSettings = ServiceSettings(),
        activity: ActivityStore? = nil,
        updater: AppUpdater? = nil,
        resets: ResetWatcher? = nil,
        detectInstalled: () -> Set<Service> = { ServiceSettings.detectInstalled() }
    ) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.codexLive = codexLive
        self.claudeLive = claudeLive
        // Against the fake server (`LIMITA_DEEPSEEK_API`) no key is needed.
        self.deepseekLive = deepseekLive ?? DeepSeekClient(apiKey: {
            try deepseekKey.read() ?? (DeepSeekClient.apiOverride == nil ? nil : "fake")
        })
        self.deepseekKey = deepseekKey
        self.ledger = ledger
        self.configurator = configurator
        self.settings = settings
        self.activity = activity ?? ActivityStore()
        self.updater = updater ?? AppUpdater()
        self.resets = resets ?? ResetWatcher(defaults: settings.defaults)
        let enabled = settings.load {
            var detected = detectInstalled()
            // An existing status-line hook means the user already chose Claude.
            if case .installed = try? configurator.status() { detected.insert(.claude) }
            return detected
        }
        enabledServices = Service.allCases.filter(enabled.contains)
        hoverEnabled = settings.hoverEnabled
        floatingEnabled = settings.floatingEnabled
        collapsedMeters = settings.collapsedMeters
        liveIntervals = settings.liveIntervals
        lowBalanceThreshold = settings.lowBalanceThreshold
        balanceAlertsEnabled = settings.balanceAlertsEnabled
        self.resets.trackedServices = { [weak self] in self?.enabledServices ?? [] }
    }

    func isCollapsed(_ meter: String, of service: Service) -> Bool {
        collapsedMeters.contains("\(service.rawValue).\(meter)")
    }

    func setCollapsed(_ collapsed: Bool, _ meter: String, of service: Service) {
        let key = "\(service.rawValue).\(meter)"
        if collapsed { collapsedMeters.insert(key) } else { collapsedMeters.remove(key) }
    }

    func isEnabled(_ service: Service) -> Bool {
        enabledServices.contains(service)
    }

    func state(for service: Service) -> ServiceState {
        states[service] ?? .unavailable(reason: "\(service.displayName) data not read yet")
    }

    func startAutoRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.localInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = Self.localInterval / 6
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh(live: true)
    }

    /// Recomputes `primeTimeServices` and wakes again at the next start or end of peak
    /// hours. Every refresh also calls it, in case the timer fired late after sleep.
    func updatePrimeTime(now: Date = Date()) {
        let active = enabledServices.filter { $0.primeTime?.contains(now) == true }
        if active != primeTimeServices {
            primeTimeServices = active
            writeTerminalSnapshot()
        }

        primeTimeTimer?.invalidate()
        primeTimeTimer = nil
        guard let next = Service.allCases.compactMap({ $0.primeTime?.nextChange(after: now) }).min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePrimeTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        primeTimeTimer = timer
    }

    /// Re-reads local sources unless that happened within `maxAge` — for opening the panel.
    func refreshIfOlder(than maxAge: TimeInterval) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        refresh()
    }

    /// Reads local sources, and also asks the network for each service when `live` is set
    /// or its last network attempt is older than its `liveInterval`. Disabled services are skipped.
    func refresh(live forceLive: Bool = false) {
        if forceLive { activity.refresh(enabledServices) }
        guard !isRefreshing else {
            // A manual refresh during a background local read must not be lost.
            if forceLive { pendingLive = true }
            return
        }
        let now = Date()
        updatePrimeTime(now: now)
        // Timer ticks drift by up to their tolerance, so allow half a tick of slack
        // to keep an interval from slipping by a whole tick.
        let slack = Self.localInterval / 2
        func isDue(_ service: Service) -> Bool {
            if let paused = livePausedUntil[service], now < paused { return false }
            return forceLive || lastLiveAttempt[service].map {
                now.timeIntervalSince($0) >= liveInterval(for: service) - slack
            } ?? true
        }
        let services = enabledServices
        let due = services.filter(isDue)
        isRefreshing = true
        for service in due { lastLiveAttempt[service] = now }

        let locals = services.compactMap { service in localSource(for: service).map { (service, $0) } }
        let remotes = due.map { ($0, liveSource(for: $0)) }

        Task {
            var localStates: [Service: ServiceState] = [:]
            var results: [Service: Result<LiveReading, Error>] = [:]
            await withTaskGroup(of: RefreshPart.self) { group in
                for (service, read) in locals {
                    group.addTask { .local(service, await Task.detached(priority: .utility) { read() }.value) }
                }
                for (service, fetch) in remotes {
                    group.addTask { .live(service, await Self.fetch(fetch)) }
                }
                for await part in group {
                    switch part {
                    case .local(let service, let state): localStates[service] = state
                    case .live(let service, let result): results[service] = result
                    }
                }
            }

            // A service disconnected while this refresh ran must stay cleared.
            for service in Service.allCases where isEnabled(service) {
                apply(results[service].map(enriched), to: service)
                if let local = localStates[service] {
                    states[service] = Self.merge(local, live: liveSnapshots[service], staleAfter: staleAfter(for: service))
                } else if localSource(for: service) == nil {
                    states[service] = liveOnlyState(service)
                }
                if service.kind == .limits {
                    resets.observe(service, snapshot: states[service]?.snapshot, details: details[service])
                }
            }
            lastRefresh = Date()
            isRefreshing = false
            writeTerminalSnapshot()

            if pendingLive {
                pendingLive = false
                refresh(live: true)
            }
        }
    }

    private enum RefreshPart: Sendable {
        case local(Service, ServiceState)
        case live(Service, Result<LiveReading, Error>)
    }

    /// The service's cheap local read, `nil` for one with only a network source.
    private func localSource(for service: Service) -> (@Sendable () -> ServiceState)? {
        switch service {
        case .codex:
            let reader = codexReader
            return { reader.read() }
        case .claude:
            let reader = claudeReader
            let configurator = configurator
            return {
                let hooked: Bool
                if case .installed = try? configurator.status() { hooked = true } else { hooked = false }
                return reader.read(isConnected: hooked)
            }
        case .deepseek:
            return nil
        }
    }

    private func liveSource(for service: Service) -> @Sendable () async throws -> LiveReading {
        switch service {
        case .codex:
            let client = codexLive
            return { try client.fetch() }
        case .claude:
            let client = claudeLive
            return { try await client.fetch() }
        case .deepseek:
            let client = deepseekLive
            return { try await client.fetch() }
        }
    }

    /// A service without a local source shows its last network reading, or why there is none.
    private func liveOnlyState(_ service: Service) -> ServiceState? {
        if let snapshot = liveSnapshots[service] {
            return .from(snapshot, staleAfter: staleAfter(for: service))
        }
        if let error = liveErrors[service] { return .unavailable(reason: error) }
        return states[service]
    }

    /// How long to leave a service's network API alone after its `streak`-th 429 in a
    /// row: 5 minutes, doubling up to half an hour, or longer if the server asks.
    nonisolated static func rateLimitPause(streak: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let backoff = min(5 * 60 * pow(2, Double(max(streak, 1) - 1)), 30 * 60)
        return max(backoff, min(retryAfter ?? 0, 2 * 60 * 60))
    }

    private nonisolated static func fetch(
        _ body: @escaping @Sendable () async throws -> LiveReading
    ) async -> Result<LiveReading, Error> {
        await Task.detached(priority: .utility) {
            do { return .success(try await body()) } catch { return .failure(error) }
        }.value
    }

    private func apply(_ result: Result<LiveReading, Error>?, to service: Service) {
        switch result {
        case .success(let reading):
            liveSnapshots[service] = reading.snapshot
            details[service] = reading.details
            liveErrors[service] = nil
            rateLimitStreak[service] = nil
            livePausedUntil[service] = nil
        case .failure(let error as any RateLimitedError):
            let streak = (rateLimitStreak[service] ?? 0) + 1
            rateLimitStreak[service] = streak
            let pause = Self.rateLimitPause(streak: streak, retryAfter: error.retryAfter)
            livePausedUntil[service] = Date().addingTimeInterval(pause)
            let message = "\(error.localizedDescription), trying again in \(Int((pause / 60).rounded(.up))) min"
            liveErrors[service] = message
            log.error("\(service.rawValue, privacy: .public) live fetch failed: \(message, privacy: .public)")
        case .failure(let error):
            // Keep the last good snapshot and extras; only record why this fetch failed.
            let message = error.localizedDescription
            liveErrors[service] = message
            log.error("\(service.rawValue, privacy: .public) live fetch failed: \(message, privacy: .public)")
        case nil:
            break
        }
    }

    /// Shows whichever of the local and network snapshots is newer.
    nonisolated static func merge(
        _ local: ServiceState, live: LimitSnapshot?, staleAfter: TimeInterval, now: Date = Date()
    ) -> ServiceState {
        guard let live else { return local }
        if let localSnapshot = local.snapshot, localSnapshot.capturedAt >= live.capturedAt {
            // Otherwise the per-model meters and the unlimited 5-hour meter would vanish
            // after every Claude Code reply.
            return .from(localSnapshot.keepingLiveData(from: live), staleAfter: staleAfter, now: now)
        }
        return .from(live, staleAfter: staleAfter, now: now)
    }

    // MARK: - Connecting services

    /// Starts tracking `service`. For Claude this also installs the status-line hook,
    /// which wraps any existing status line; its outcome is left in `setupMessage`.
    func connect(_ service: Service) {
        guard !isEnabled(service) else { return }
        // DeepSeek connects with a key: `connectDeepSeek(apiKey:)`, from Settings.
        if service == .deepseek, deepseekKeyHint() == nil {
            setupMessage = (.deepseek, DeepSeekClient.MissingKey().localizedDescription)
            return
        }
        if service == .claude {
            setupMessage = (.claude, installClaudeHook())
        }
        setEnabled(service, true)
        refresh(live: true)
        resets.refresh()
    }

    /// Checks `apiKey` against DeepSeek and, if it works, stores it in the Keychain and
    /// starts tracking DeepSeek (or switches to the new key). Returns why it did not work;
    /// a rejected key is never stored.
    func connectDeepSeek(apiKey: String) async -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Enter a DeepSeek API key" }
        let reading: LiveReading
        do {
            reading = try await deepseekLive.fetch(key: key)
        } catch {
            return error.localizedDescription
        }
        do {
            // Another key may be another account: its history would read as spending.
            if (try? deepseekKey.read()) != key { ledger.clear() }
            try deepseekKey.save(key)
        } catch {
            return error.localizedDescription
        }
        if !isEnabled(.deepseek) { setEnabled(.deepseek, true) }
        lastLiveAttempt[.deepseek] = Date()
        apply(enriched(.success(reading)), to: .deepseek)
        states[.deepseek] = liveOnlyState(.deepseek)
        writeTerminalSnapshot()
        return nil
    }

    /// The stored DeepSeek key as "sk-…1a2b", `nil` without one. Reads the Keychain.
    func deepseekKeyHint() -> String? {
        guard let key = try? deepseekKey.read(), !key.isEmpty else { return nil }
        return Self.keyHint(key)
    }

    nonisolated static func keyHint(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let prefix = key.hasPrefix("sk-") ? "sk-" : ""
        return "\(prefix)…\(key.suffix(4))"
    }

    /// Stops tracking `service` and drops its data. For Claude this also removes the
    /// status-line hook and restores the previous status line; for DeepSeek it removes
    /// the API key from the Keychain and the balance history.
    func disconnect(_ service: Service) {
        guard isEnabled(service) else { return }
        if service == .claude {
            do {
                try configurator.uninstall()
            } catch {
                setupMessage = (.claude, "Could not restore the Claude Code status line: \(error.localizedDescription)")
            }
        }
        if service == .deepseek {
            do {
                try deepseekKey.delete()
            } catch {
                setupMessage = (.deepseek, error.localizedDescription)
            }
            ledger.clear()
        }
        setEnabled(service, false)
        states[service] = nil
        liveErrors[service] = nil
        details[service] = nil
        liveSnapshots[service] = nil
        writeTerminalSnapshot()
    }

    // MARK: - DeepSeek balance

    /// A DeepSeek reading with what the balance history says, after recording it there.
    /// Also announces a balance that just went low or ran out.
    private func enriched(_ result: Result<LiveReading, Error>) -> Result<LiveReading, Error> {
        guard case .success(let reading) = result, let balance = reading.snapshot.balance else { return result }
        let captured = reading.snapshot.capturedAt
        let summary = ledger.record(total: balance.total, currency: balance.currency, at: captured)
        let full = balance.with(summary, lowThreshold: lowBalanceThreshold)
        announceBalance(full)
        return .success(LiveReading(snapshot: LimitSnapshot(balance: full, capturedAt: captured), details: reading.details))
    }

    /// One notification per drop below the threshold and per running out; each is armed
    /// again once the balance recovers.
    private func announceBalance(_ balance: Balance) {
        let service = Service.deepseek
        if !balance.isAvailable {
            if !ledger.alertedUnavailable, balanceAlertsEnabled {
                alert("\(service.rawValue)-unavailable-\(Int(Date().timeIntervalSince1970))",
                      "\(service.displayName) balance ran out",
                      "API calls are rejected until you top up. \(balance.format(balance.total)) left.")
            }
            ledger.alertedUnavailable = true
            ledger.alertedLow = true
            return
        }
        ledger.alertedUnavailable = false
        guard balance.isLow, let threshold = balance.lowThreshold else {
            ledger.alertedLow = false
            return
        }
        if !ledger.alertedLow, balanceAlertsEnabled {
            alert("\(service.rawValue)-low-\(Int(Date().timeIntervalSince1970))",
                  "\(service.displayName) balance is low",
                  "\(balance.format(balance.total)) left, at or below your \(balance.format(threshold)) alert.")
        }
        ledger.alertedLow = true
    }

    /// Shows a changed threshold right away, without waiting for the next fetch.
    private func reapplyBalanceThreshold() {
        guard let snapshot = liveSnapshots[.deepseek], var balance = snapshot.balance else { return }
        balance.lowThreshold = lowBalanceThreshold
        liveSnapshots[.deepseek] = LimitSnapshot(balance: balance, capturedAt: snapshot.capturedAt)
        states[.deepseek] = liveOnlyState(.deepseek)
        if !balance.isLow { ledger.alertedLow = false }
        writeTerminalSnapshot()
    }

    /// Mirrors the dashboard to `TerminalSnapshot.fileURL` for the iTerm2 script.
    private func writeTerminalSnapshot() {
        let snapshot = TerminalSnapshot(
            services: enabledServices, states: state(for:), primeTime: primeTimeServices, staleAfter: staleAfter(for:)
        )
        guard snapshot != writtenSnapshot else { return }
        do {
            try snapshot.write()
            writtenSnapshot = snapshot
        } catch {
            log.error("snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setEnabled(_ service: Service, _ enabled: Bool) {
        var set = Set(enabledServices)
        if enabled { set.insert(service) } else { set.remove(service) }
        enabledServices = Service.allCases.filter(set.contains)
        settings.save(set)
        updatePrimeTime()
    }

    private func installClaudeHook() -> String {
        let hint = configurator.isRunningFromStableLocation
            ? ""
            : "\nLimita is not running from /Applications: move it there and connect again."
        do {
            switch try configurator.install() {
            case .installed:
                return "Connected. Limits appear right away; the status line adds a fallback." + hint
            case .wrapped:
                return "Connected. Your Claude Code status line is kept and works as before." + hint
            case .updated:
                return "Connected. Updated the Limita path in Claude Code settings." + hint
            case .alreadyConfigured:
                return "Connected."
            }
        } catch {
            return "Connected, but the status line was not set up: \(error.localizedDescription)"
        }
    }

    /// Silently fixes a hook left pointing at a moved or deleted copy of the app.
    func repairClaudeHookIfNeeded() {
        guard isEnabled(.claude) else { return }
        _ = try? configurator.repairIfNeeded()
    }
}
