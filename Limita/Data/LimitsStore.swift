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

    static func liveInterval(for service: Service) -> TimeInterval {
        switch service {
        case .claude: 3 * 60
        case .codex: 5 * 60
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
    /// Result of the last connect/disconnect, for the service it concerns.
    var setupMessage: (service: Service, text: String)?
    /// Whether the menu-bar icon is shown. Not saved: every launch starts with the icon,
    /// so its menu (Connect, Quit) is always reachable after a restart.
    var showsMenuBarIcon = true {
        didSet { onMenuBarIconChange?(showsMenuBarIcon) }
    }
    @ObservationIgnored var onMenuBarIconChange: ((Bool) -> Void)?

    /// Newest snapshot fetched over the network per service.
    @ObservationIgnored private var liveSnapshots: [Service: LimitSnapshot] = [:]
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastLiveAttempt: [Service: Date] = [:]
    @ObservationIgnored private var pendingLive = false
    @ObservationIgnored private let codexReader: CodexLimitsReader
    @ObservationIgnored private let claudeReader: ClaudeLimitsReader
    @ObservationIgnored private let codexLive: CodexLiveClient
    @ObservationIgnored private let claudeLive: ClaudeLiveClient
    @ObservationIgnored private let configurator: ClaudeStatusLineConfigurator
    @ObservationIgnored private let settings: ServiceSettings
    @ObservationIgnored private let log = Logger(subsystem: "com.limita.app", category: "refresh")

    init(
        codexReader: CodexLimitsReader = CodexLimitsReader(),
        claudeReader: ClaudeLimitsReader = ClaudeLimitsReader(),
        codexLive: CodexLiveClient = CodexLiveClient(),
        claudeLive: ClaudeLiveClient = ClaudeLiveClient(),
        configurator: ClaudeStatusLineConfigurator = ClaudeStatusLineConfigurator(),
        settings: ServiceSettings = ServiceSettings(),
        detectInstalled: () -> Set<Service> = { ServiceSettings.detectInstalled() }
    ) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.codexLive = codexLive
        self.claudeLive = claudeLive
        self.configurator = configurator
        self.settings = settings
        let enabled = settings.load {
            var detected = detectInstalled()
            // An existing status-line hook means the user already chose Claude.
            if case .installed = try? configurator.status() { detected.insert(.claude) }
            return detected
        }
        enabledServices = Service.allCases.filter(enabled.contains)
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

    /// Re-reads local sources unless that happened within `maxAge` — for opening the panel.
    func refreshIfOlder(than maxAge: TimeInterval) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        refresh()
    }

    /// Reads local sources, and also asks the network for each service when `live` is set
    /// or its last network attempt is older than its `liveInterval`. Disabled services are skipped.
    func refresh(live forceLive: Bool = false) {
        guard !isRefreshing else {
            // A manual refresh during a background local read must not be lost.
            if forceLive { pendingLive = true }
            return
        }
        let now = Date()
        // Timer ticks drift by up to their tolerance, so allow half a tick of slack
        // to keep an interval from slipping by a whole tick.
        let slack = Self.localInterval / 2
        func isDue(_ service: Service) -> Bool {
            forceLive || lastLiveAttempt[service].map {
                now.timeIntervalSince($0) >= Self.liveInterval(for: service) - slack
            } ?? true
        }
        let codexOn = isEnabled(.codex)
        let claudeOn = isEnabled(.claude)
        let codexLiveDue = codexOn && isDue(.codex)
        let claudeLiveDue = claudeOn && isDue(.claude)
        isRefreshing = true
        if codexLiveDue { lastLiveAttempt[.codex] = now }
        if claudeLiveDue { lastLiveAttempt[.claude] = now }

        let codexReader = codexReader
        let claudeReader = claudeReader
        let codexLive = codexLive
        let claudeLive = claudeLive
        let configurator = configurator

        Task {
            async let codexLocal = codexOn
                ? Task.detached(priority: .utility) { codexReader.read() }.value
                : nil
            async let claudeLocal = claudeOn
                ? Task.detached(priority: .utility) {
                    let hooked: Bool
                    if case .installed = try? configurator.status() { hooked = true } else { hooked = false }
                    return claudeReader.read(isConnected: hooked)
                }.value
                : nil
            async let codexRemote = codexLiveDue ? Self.fetch { try codexLive.fetch() } : nil
            async let claudeRemote = claudeLiveDue ? Self.fetch { try await claudeLive.fetch() } : nil

            let (codexState, claudeState) = await (codexLocal, claudeLocal)
            let (codexResult, claudeResult) = await (codexRemote, claudeRemote)

            // A service disconnected while this refresh ran must stay cleared.
            if isEnabled(.codex) {
                apply(codexResult, to: .codex)
                if let codexState {
                    states[.codex] = merge(codexState, live: liveSnapshots[.codex], staleAfter: CodexLimitsReader.staleAfter)
                }
            }
            if isEnabled(.claude) {
                apply(claudeResult, to: .claude)
                if let claudeState {
                    states[.claude] = merge(claudeState, live: liveSnapshots[.claude], staleAfter: ClaudeLimitsReader.staleAfter)
                }
            }
            lastRefresh = Date()
            isRefreshing = false

            if pendingLive {
                pendingLive = false
                refresh(live: true)
            }
        }
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
    private func merge(_ local: ServiceState, live: LimitSnapshot?, staleAfter: TimeInterval) -> ServiceState {
        guard let live else { return local }
        if let localSnapshot = local.snapshot, localSnapshot.capturedAt >= live.capturedAt {
            return local
        }
        return .from(live, staleAfter: staleAfter)
    }

    // MARK: - Connecting services

    /// Starts tracking `service`. For Claude this also installs the status-line hook,
    /// which wraps any existing status line; its outcome is left in `setupMessage`.
    func connect(_ service: Service) {
        guard !isEnabled(service) else { return }
        if service == .claude {
            setupMessage = (.claude, installClaudeHook())
        }
        setEnabled(service, true)
        refresh(live: true)
    }

    /// Stops tracking `service` and drops its data. For Claude this also removes the
    /// status-line hook and restores the previous status line.
    func disconnect(_ service: Service) {
        guard isEnabled(service) else { return }
        if service == .claude {
            do {
                try configurator.uninstall()
            } catch {
                setupMessage = (.claude, "Could not restore the Claude Code status line: \(error.localizedDescription)")
            }
        }
        setEnabled(service, false)
        states[service] = nil
        liveErrors[service] = nil
        details[service] = nil
        liveSnapshots[service] = nil
    }

    private func setEnabled(_ service: Service, _ enabled: Bool) {
        var set = Set(enabledServices)
        if enabled { set.insert(service) } else { set.remove(service) }
        enabledServices = Service.allCases.filter(set.contains)
        settings.save(set)
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
