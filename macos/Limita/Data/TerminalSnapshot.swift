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
        let capturedAt: Date?
        /// Seconds after `capturedAt` when the data counts as stale. The reader decides,
        /// so a file left behind by a crashed app goes stale on its own.
        let staleAfter: TimeInterval
        let primeTime: Bool
    }

    var version = 1
    let services: [Entry]

    init(services: [Service], states: (Service) -> ServiceState, primeTime: [Service]) {
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
                capturedAt: snapshot?.capturedAt,
                staleAfter: service == .claude ? ClaudeLimitsReader.staleAfter : CodexLimitsReader.staleAfter,
                primeTime: primeTime.contains(service)
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
