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

    /// A window whose reset time has passed carries a stale percentage: the CLI has not
    /// run since the reset, so its last reported number describes the previous window.
    func isExpired(at now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// The percentage to display: an expired window has started over at zero.
    func displayPercent(at now: Date = Date()) -> Double {
        isExpired(at: now) ? 0 : usedPercent
    }

    /// Clamped to 0...1 for progress bars.
    func displayFraction(at now: Date = Date()) -> Double {
        min(max(displayPercent(at: now) / 100, 0), 1)
    }

    func percentText(at now: Date = Date()) -> String {
        String(format: "%.0f%%", displayPercent(at: now))
    }

    func resetText(at now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        if resetsAt <= now { return "window reset" }
        return "resets \(resetsAt.formatted(.relative(presentation: .numeric).locale(.english)))"
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

    /// Highest pressure across both windows, for status dots.
    func peakFraction(at now: Date = Date()) -> Double {
        [fiveHour, sevenDay]
            .compactMap { $0?.displayFraction(at: now) }
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

    var symbolName: String {
        switch self {
        case .codex: "bolt.fill"
        case .claude: "sparkles"
        }
    }
}

/// Balances and extras beyond the rate-limit windows. Only the network sources report
/// these; a field is `nil` when the service did not report it, and the UI hides it.
struct AccountDetails: Sendable, Equatable {
    /// A prepaid dollar allowance, e.g. Claude's cloud session credits.
    struct Allowance: Sendable, Equatable {
        let remaining: Double
        let limit: Double?
        let expiresAt: Date?
    }

    enum UsageCredits: Sendable, Equatable {
        case off
        case balance(dollars: Double)
        case spent(dollars: Double, limit: Double?)
    }

    /// Codex sells credits at $1 = 25 credits (1 credit = $0.04).
    static let codexCreditsPerDollar: Double = 25

    /// Codex: rate-limit reset credits available to redeem.
    var limitResets: Int?
    /// Codex: credit balance, in credits.
    var codexCredits: Double?
    var codexCreditsUnlimited = false
    /// Claude: credits that cover usage beyond the plan limits.
    var claudeUsageCredits: UsageCredits?
    /// Claude: cloud session credits.
    var cloudCredits: Allowance?

    var isEmpty: Bool {
        limitResets == nil && codexCredits == nil && !codexCreditsUnlimited
            && claudeUsageCredits == nil && cloudCredits == nil
    }
}

/// What a network source returns: the windows plus any account details.
struct LiveReading: Sendable, Equatable {
    let snapshot: LimitSnapshot
    let details: AccountDetails
}

extension Locale {
    /// The UI is English regardless of the system language.
    static let english = Locale(identifier: "en_US")
}
