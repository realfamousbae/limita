import Foundation
import Observation

@Observable
@MainActor
final class LimitsStore {
    var codex: ServiceStatus = .empty
    var claude: ServiceStatus = .empty

    private var refreshTimer: Timer?
    private let codexScraper = OpenAIScraper()
    private let claudeScraper = ClaudeScraper()

    private enum Keys {
        static let codex = "limita.codex"
        static let claude = "limita.claude"
    }

    init() {
        load()
        scheduleRefresh()
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: Keys.codex),
           let status = try? decoder.decode(ServiceStatus.self, from: data) {
            codex = status
        }
        if let data = UserDefaults.standard.data(forKey: Keys.claude),
           let status = try? decoder.decode(ServiceStatus.self, from: data) {
            claude = status
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(codex) {
            UserDefaults.standard.set(data, forKey: Keys.codex)
        }
        if let data = try? encoder.encode(claude) {
            UserDefaults.standard.set(data, forKey: Keys.claude)
        }
    }

    // MARK: - Refresh

    func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard codex.isLoggedIn || claude.isLoggedIn else { return }

        async let codexResult = codex.isLoggedIn ? codexScraper.fetchLimits() : nil
        async let claudeResult = claude.isLoggedIn ? claudeScraper.fetchLimits() : nil

        let (newCodex, newClaude) = await (codexResult, claudeResult)
        if let c = newCodex { codex = c }
        if let cl = newClaude { claude = cl }
        save()
    }

    // MARK: - Login state

    func markLoggedIn(_ service: Service) {
        switch service {
        case .codex:
            codex.isLoggedIn = true
            codex.errorMessage = nil
        case .claude:
            claude.isLoggedIn = true
            claude.errorMessage = nil
        }
        save()
        Task { await refresh() }
    }
}
