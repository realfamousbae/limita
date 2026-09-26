import Foundation

/// Reads the sanitized payload written by Limita's Claude Code status-line hook.
struct ClaudeLimitsReader: Sendable {
    static let staleAfter: TimeInterval = 30 * 60

    let cacheFile: URL

    init(cacheFile: URL = ClaudeStatusCache.fileURL) {
        self.cacheFile = cacheFile
    }

    /// `isConnected` only picks the wording of the "no data" reason: the cache may
    /// still hold data from before the hook was removed, which is shown as stale.
    func read(isConnected: Bool, now: Date = Date()) -> ServiceState {
        guard let data = try? Data(contentsOf: cacheFile) else {
            return .unavailable(reason: isConnected
                ? "Start Claude Code — limits appear after its first response"
                : "Connect Claude Code to see its limits")
        }

        guard let cache = try? ClaudeStatusCache.decoder.decode(ClaudeStatusCache.self, from: data) else {
            return .unavailable(reason: "Claude cache is corrupted — wait for the next Claude Code response")
        }

        let snapshot = cache.snapshot
        guard !snapshot.isEmpty else {
            return .unavailable(reason: "Claude Code has not reported limits yet")
        }
        return .from(snapshot, staleAfter: Self.staleAfter, now: now)
    }
}

/// The only data persisted from Claude's status-line JSON. No transcript, prompt,
/// project path, account information, or credential is retained.
struct ClaudeStatusCache: Codable, Sendable, Equatable {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
    let capturedAt: Date

    var snapshot: LimitSnapshot {
        LimitSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, capturedAt: capturedAt)
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limita", isDirectory: true)
            .appendingPathComponent("claude-status.json")
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
