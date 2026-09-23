import Foundation
import Observation

@Observable
@MainActor
final class LimitsStore {
    private(set) var codex: ServiceState = .unavailable(reason: "Данные Codex ещё не прочитаны")
    private(set) var claude: ServiceState = .unavailable(reason: "Данные Claude ещё не прочитаны")
    private(set) var isRefreshing = false

    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private let codexReader: CodexLimitsReader
    @ObservationIgnored private let claudeReader: ClaudeLimitsReader

    init(
        codexReader: CodexLimitsReader = CodexLimitsReader(),
        claudeReader: ClaudeLimitsReader = ClaudeLimitsReader()
    ) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let codexReader = self.codexReader
        let claudeReader = self.claudeReader

        async let codexState = Task.detached(priority: .utility) {
            codexReader.read()
        }.value
        async let claudeState = Task.detached(priority: .utility) {
            claudeReader.read()
        }.value

        let results = await (codexState, claudeState)
        codex = results.0
        claude = results.1
    }

    func configureClaudeStatusLine() -> String {
        do {
            let outcome = try ClaudeStatusLineConfigurator().configure()
            switch outcome {
            case .installed:
                claude = .unavailable(reason: "Готово. Запустите Claude Code: данные появятся после обновления status line.")
                return "Limita подключена к Claude Code. Запустите или продолжите сессию — после обновления status line появятся лимиты."
            case .updated:
                return "Путь к Limita в настройках Claude Code обновлён."
            case .alreadyConfigured:
                return "Limita уже подключена к Claude Code."
            }
        } catch {
            return error.localizedDescription
        }
    }
}
