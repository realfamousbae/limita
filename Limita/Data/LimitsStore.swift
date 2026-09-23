import Foundation
import Observation

@Observable
@MainActor
final class LimitsStore {
    /// Local sources (Codex session logs, Claude status-line cache) are cheap and read
    /// every minute; the network is asked every `liveInterval` or on manual refresh.
    static let localInterval: TimeInterval = 60
    static let liveInterval: TimeInterval = 20 * 60

    private(set) var codex: ServiceState = .unavailable(reason: "Codex data not read yet")
    private(set) var claude: ServiceState = .unavailable(reason: "Claude data not read yet")
    /// Whether Limita's hook is in Claude Code's settings.
    private(set) var isClaudeConnected = false
    /// Last network error per service, shown when the displayed data is stale.
    private(set) var liveErrors: [Service: String] = [:]
    private(set) var isRefreshing = false
    /// Newest snapshot fetched over the network per service.
    private var liveSnapshots: [Service: LimitSnapshot] = [:]
    /// Balances and extras from the last successful network read.
    private(set) var details: [Service: AccountDetails] = [:]
    /// Result of the last connect/disconnect action, shown inline in the panel.
    var claudeSetupMessage: String?

    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastLiveAttempt: Date?
    @ObservationIgnored private var pendingLive = false
    @ObservationIgnored private let codexReader: CodexLimitsReader
    @ObservationIgnored private let claudeReader: ClaudeLimitsReader
    @ObservationIgnored private let codexLive: CodexLiveClient
    @ObservationIgnored private let claudeLive: ClaudeLiveClient
    @ObservationIgnored private let configurator: ClaudeStatusLineConfigurator

    init(
        codexReader: CodexLimitsReader = CodexLimitsReader(),
        claudeReader: ClaudeLimitsReader = ClaudeLimitsReader(),
        codexLive: CodexLiveClient = CodexLiveClient(),
        claudeLive: ClaudeLiveClient = ClaudeLiveClient(),
        configurator: ClaudeStatusLineConfigurator = ClaudeStatusLineConfigurator()
    ) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.codexLive = codexLive
        self.claudeLive = claudeLive
        self.configurator = configurator
    }

    /// Claude data that does not depend on the status-line hook, so "Connect" is optional.
    var hasClaudeLiveData: Bool { liveSnapshots[.claude] != nil }

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

    /// Reads local sources, and also asks the network when `live` is set or the last
    /// network attempt is older than `liveInterval`.
    func refresh(live forceLive: Bool = false) {
        guard !isRefreshing else {
            // A manual refresh during a background local read must not be lost.
            if forceLive { pendingLive = true }
            return
        }
        let now = Date()
        let live = forceLive || lastLiveAttempt.map { now.timeIntervalSince($0) >= Self.liveInterval } ?? true
        isRefreshing = true
        if live { lastLiveAttempt = now }

        let codexReader = codexReader
        let claudeReader = claudeReader
        let codexLive = codexLive
        let claudeLive = claudeLive
        let configurator = configurator

        Task {
            async let codexLocal = Task.detached(priority: .utility) {
                codexReader.read()
            }.value
            async let claudeLocal = Task.detached(priority: .utility) {
                let connected: Bool
                if case .installed = try? configurator.status() { connected = true } else { connected = false }
                return (connected, claudeReader.read(isConnected: connected))
            }.value
            async let codexRemote = live ? Self.fetch { try codexLive.fetch() } : nil
            async let claudeRemote = live ? Self.fetch { try await claudeLive.fetch() } : nil

            let (codexState, (connected, claudeState)) = await (codexLocal, claudeLocal)
            let (codexResult, claudeResult) = await (codexRemote, claudeRemote)

            apply(codexResult, to: .codex)
            apply(claudeResult, to: .claude)
            codex = merge(codexState, live: liveSnapshots[.codex], staleAfter: CodexLimitsReader.staleAfter)
            claude = merge(claudeState, live: liveSnapshots[.claude], staleAfter: ClaudeLimitsReader.staleAfter)
            isClaudeConnected = connected
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
            liveErrors[service] = error.localizedDescription
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

    // MARK: - Claude status line

    func connectClaude() {
        do {
            let hint = configurator.isRunningFromStableLocation
                ? ""
                : "\nLimita is not running from /Applications: move it there and connect again."
            switch try configurator.install() {
            case .installed:
                claudeSetupMessage = "Connected. Limits appear after the next Claude Code response." + hint
            case .wrapped:
                claudeSetupMessage = "Connected. Your status line is kept and works as before." + hint
            case .updated:
                claudeSetupMessage = "Updated the Limita path in Claude Code settings." + hint
            case .alreadyConfigured:
                claudeSetupMessage = "Limita is already connected to Claude Code."
            }
        } catch {
            claudeSetupMessage = error.localizedDescription
        }
        refresh()
    }

    func disconnectClaude() {
        do {
            try configurator.uninstall()
            claudeSetupMessage = "Disconnected from Claude Code; your previous status line is restored."
        } catch {
            claudeSetupMessage = error.localizedDescription
        }
        refresh()
    }

    /// Silently fixes a hook left pointing at a moved or deleted copy of the app.
    func repairClaudeHookIfNeeded() {
        _ = try? configurator.repairIfNeeded()
    }
}
