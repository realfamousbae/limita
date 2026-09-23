import Foundation
import Observation

@Observable
@MainActor
final class LimitsStore {
    private(set) var codex: ServiceState = .unavailable(reason: "Данные Codex ещё не прочитаны")
    private(set) var claude: ServiceState = .unavailable(reason: "Данные Claude ещё не прочитаны")
    /// Whether Limita's hook is in Claude Code's settings. Drives the "Connect" button,
    /// independently of whether cached data exists.
    private(set) var isClaudeConnected = false
    private(set) var isRefreshing = false
    /// Result of the last connect/disconnect action, shown inline in the panel.
    var claudeSetupMessage: String?

    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private let codexReader: CodexLimitsReader
    @ObservationIgnored private let claudeReader: ClaudeLimitsReader
    @ObservationIgnored private let configurator: ClaudeStatusLineConfigurator

    init(
        codexReader: CodexLimitsReader = CodexLimitsReader(),
        claudeReader: ClaudeLimitsReader = ClaudeLimitsReader(),
        configurator: ClaudeStatusLineConfigurator = ClaudeStatusLineConfigurator()
    ) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.configurator = configurator
    }

    func startAutoRefresh(interval: TimeInterval = 60) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval / 6
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    /// Refreshes unless data was read within `maxAge` — for opening the panel.
    func refreshIfOlder(than maxAge: TimeInterval) {
        guard let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge else {
            refresh()
            return
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let codexReader = codexReader
        let claudeReader = claudeReader
        let configurator = configurator

        Task {
            async let codexState = Task.detached(priority: .utility) {
                codexReader.read()
            }.value
            async let claudeResult = Task.detached(priority: .utility) {
                let connected: Bool
                if case .installed = try? configurator.status() { connected = true } else { connected = false }
                return (connected, claudeReader.read(isConnected: connected))
            }.value

            let (codex, (connected, claude)) = await (codexState, claudeResult)
            self.codex = codex
            self.claude = claude
            self.isClaudeConnected = connected
            self.lastRefresh = Date()
            self.isRefreshing = false
        }
    }

    func connectClaude() {
        do {
            let hint = configurator.isRunningFromBuildDirectory
                ? "\nLimita запущена из папки сборки: перенесите её в /Applications и подключите заново."
                : ""
            switch try configurator.install() {
            case .installed:
                claudeSetupMessage = "Подключено. Лимиты появятся после следующего ответа Claude Code." + hint
            case .wrapped:
                claudeSetupMessage = "Подключено. Ваша status line сохранена и работает как раньше." + hint
            case .updated:
                claudeSetupMessage = "Путь к Limita в настройках Claude Code обновлён." + hint
            case .alreadyConfigured:
                claudeSetupMessage = "Limita уже подключена к Claude Code."
            }
        } catch {
            claudeSetupMessage = error.localizedDescription
        }
        refresh()
    }

    func disconnectClaude() {
        do {
            try configurator.uninstall()
            claudeSetupMessage = "Limita отключена от Claude Code, прежняя status line восстановлена."
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
