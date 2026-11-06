import Foundation

/// What the dashboard shows, written to a file for tools outside the app: the iTerm2
/// status-bar script in `integrations/iterm2` reads it. Raw windows rather than
/// formatted text, so a reader can count down to the reset between two writes.
struct TerminalSnapshot: Encodable, Equatable {
    struct Entry: Encodable, Equatable {
        let id: String
        let name: String
        /// "used" (Claude) or "left" (Codex): how the percentage is shown.
        let meaning: String
        /// "fresh", "stale" or "unavailable".
        let status: String
        let reason: String?
        let fiveHour: LimitWindow?
        let sevenDay: LimitWindow?
        let hasNoFiveHourLimit: Bool
        /// Days in the `sevenDay` window: 7, or 30 on Codex Free.
        let longWindowDays: Int
        let capturedAt: Date?
        /// Seconds after `capturedAt` when the data counts as stale. The reader decides,
        /// so a file left behind by a crashed app goes stale on its own.
        let staleAfter: TimeInterval
        let primeTime: Bool
        /// A prepaid balance instead of windows (DeepSeek); absent for the others.
        let balance: BalanceEntry?
    }

    struct BalanceEntry: Encodable, Equatable {
        let currency: String
        let total: Double
        /// "¥110.00", as the dashboard shows it.
        let text: String
        /// "normal", "warning" or "critical".
        let level: String
        let isAvailable: Bool
    }

    var version = 1
    let services: [Entry]

    init(
        services: [Service], states: (Service) -> ServiceState, primeTime: [Service],
        staleAfter: (Service) -> TimeInterval
    ) {
        self.services = services.map { service in
            let state = states(service)
            let status = switch state {
            case .unavailable: "unavailable"
            case .stale: "stale"
            case .fresh: "fresh"
            }
            let snapshot = state.snapshot
            return Entry(
                id: service.rawValue,
                name: service.displayName,
                meaning: service.percentMeaning,
                status: status,
                reason: state.unavailableReason,
                fiveHour: snapshot?.fiveHour,
                sevenDay: snapshot?.sevenDay,
                hasNoFiveHourLimit: snapshot?.hasNoFiveHourLimit ?? false,
                longWindowDays: snapshot?.longWindowSpan ?? 7,
                capturedAt: snapshot?.capturedAt,
                staleAfter: staleAfter(service),
                primeTime: primeTime.contains(service),
                balance: snapshot?.balance.map { balance in
                    BalanceEntry(
                        currency: balance.currency, total: balance.total, text: balance.format(balance.total),
                        level: balance.level.name,
                        isAvailable: balance.isAvailable
                    )
                }
            )
        }
    }

    static var fileURL: URL {
        ClaudeStatusCache.fileURL.deletingLastPathComponent().appendingPathComponent("snapshot.json")
    }

    /// On quit: without the app the numbers stop updating, so readers should say so.
    static func remove(at url: URL = TerminalSnapshot.fileURL) {
        try? FileManager.default.removeItem(at: url)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func write(to url: URL = TerminalSnapshot.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}
