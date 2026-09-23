import Foundation

/// One rate-limit window (5-hour or 7-day) as reported by a CLI.
///
/// Both Codex and Claude report a percentage directly rather than used/total counts,
/// so this is modelled around `usedPercent` — see `CodexLimitsReader` and `ClaudeLimitsReader`.
struct LimitWindow: Codable, Sendable, Equatable {
    /// 0...100, and above 100 once the limit is exceeded.
    let usedPercent: Double
    /// When the window resets. Absent if the source did not report it.
    let resetsAt: Date?

    /// Clamped to 0...1 for progress bars.
    var fraction: Double {
        min(max(usedPercent / 100, 0), 1)
    }

    /// A window whose reset time has passed carries a stale percentage: the CLI has not
    /// run since the reset, so its last reported number describes the previous window.
    var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= Date()
    }

    /// The percentage to display: an expired window has started over at zero.
    var displayPercent: Double {
        isExpired ? 0 : usedPercent
    }

    var displayFraction: Double {
        isExpired ? 0 : fraction
    }

    var percentText: String {
        String(format: "%.0f%%", displayPercent)
    }

    var resetText: String? {
        guard let resetsAt else { return nil }
        if resetsAt <= Date() { return "окно обновилось" }
        return "сброс \(resetsAt.formatted(.relative(presentation: .numeric)))"
    }
}

/// The pair of windows a service reports, plus when we read them.
struct LimitSnapshot: Codable, Sendable, Equatable {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
    let capturedAt: Date

    var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil
    }

    /// Highest pressure across both windows, for the pill's status dot.
    var peakFraction: Double {
        [fiveHour, sevenDay]
            .compactMap { $0?.displayFraction }
            .max() ?? 0
    }
}

/// What we know about one service right now.
enum ServiceState: Sendable, Equatable {
    /// No data at all — source not configured, files missing, nothing parseable.
    /// `reason` is shown to the user verbatim, so it must be actionable.
    case unavailable(reason: String)
    /// Data we read, but old enough that it may not reflect current usage.
    case stale(LimitSnapshot)
    /// Recent data.
    case fresh(LimitSnapshot)

    var snapshot: LimitSnapshot? {
        switch self {
        case .unavailable: nil
        case .stale(let s), .fresh(let s): s
        }
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    var capturedAt: Date? { snapshot?.capturedAt }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    /// Builds a state from a snapshot, deciding freshness by age.
    static func from(_ snapshot: LimitSnapshot, staleAfter: TimeInterval, now: Date = Date()) -> ServiceState {
        now.timeIntervalSince(snapshot.capturedAt) > staleAfter
            ? .stale(snapshot)
            : .fresh(snapshot)
    }
}

enum AppState: Equatable {
    case hidden
    case expanded
}

enum Service: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var icon: String {
        switch self {
        case .codex: "⚡"
        case .claude: "🤖"
        }
    }
}
