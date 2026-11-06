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

    /// What is left of the window, 0...100.
    func remainingPercent(at now: Date = Date()) -> Double {
        min(max(100 - displayPercent(at: now), 0), 100)
    }

    /// The percentage a service is displayed with — see `Service.showsRemaining`.
    func shownPercent(for service: Service, at now: Date = Date()) -> Double {
        service.showsRemaining ? remainingPercent(at: now) : min(max(displayPercent(at: now), 0), 100)
    }

    func shownText(for service: Service, at now: Date = Date()) -> String {
        String(format: "%.0f%%", shownPercent(for: service, at: now))
    }

    func resetText(at now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        if resetsAt <= now { return "window reset" }
        return "resets in \(Self.durationText(resetsAt.timeIntervalSince(now)))"
    }

    /// "2 days 4 hours 5 min", "4 hours 5 min" or "42 min". Rounded up to the minute, so
    /// it never reads "0 min" before the reset; the value changes exactly on
    /// `resetsAt` minus whole minutes (see `ResetTicks`).
    static func durationText(_ interval: TimeInterval) -> String {
        // The epsilon keeps an exact minute boundary from rounding up to the next one.
        let total = max(Int(((interval - 0.001) / 60).rounded(.up)), 1)
        let days = total / 1440
        let hours = total % 1440 / 60
        let minutes = total % 60
        func count(_ value: Int, _ one: String, _ many: String) -> String {
            "\(value) \(value == 1 ? one : many)"
        }
        if days > 0 {
            return "\(count(days, "day", "days")) \(count(hours, "hour", "hours")) \(minutes) min"
        }
        if hours > 0 {
            return "\(count(hours, "hour", "hours")) \(minutes) min"
        }
        return "\(minutes) min"
    }

    /// The longest `resetText` a window can produce (a 7-day one), for sizing the dashboard.
    static let longestResetText = "resets in 6 days 23 hours 59 min"
}

/// A window that covers one model only, e.g. Fable's own weekly limit on an Ultra plan.
struct ScopedWindow: Codable, Sendable, Equatable {
    /// The model's name as the service reports it, e.g. "Fable".
    let name: String
    /// A weekly window; otherwise a 5-hour one.
    let isWeekly: Bool
    let window: LimitWindow
    /// How much of the plan's weekly limit the model has used, and may use at most.
    /// Only weekly windows have one, and only when the service reports it.
    var weeklyShare: WeeklyShare? = nil

    /// "FABLE 7 DAYS", in the style of the other meters' titles.
    var title: String {
        "\(name.uppercased()) \(isWeekly ? "7 DAYS" : "5 HOURS")"
    }

    /// The model's part of the weekly limit, both in percent of the whole week.
    struct WeeklyShare: Codable, Sendable, Equatable {
        let usedPercent: Double
        /// "Up to 50 % of your weekly limit"; `nil` when not reported.
        let allowancePercent: Double?
    }

    /// What `weeklyShare` used, 0...100; nothing once the window has reset.
    func weeklySharePercent(at now: Date = Date()) -> Double? {
        guard isWeekly, let share = weeklyShare else { return nil }
        return window.isExpired(at: now) ? 0 : min(max(share.usedPercent, 0), 100)
    }
}

/// The pair of windows a service reports, plus when we read them.
struct LimitSnapshot: Codable, Sendable, Equatable {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
    let capturedAt: Date
    /// The source said outright that the plan has no 5-hour limit: Codex on a Team plan
    /// puts the weekly window where the 5-hour one goes, and Codex Pro or Claude Ultra
    /// reports no 5-hour window. Otherwise a missing `fiveHour` means "unknown", never
    /// "no limit": Claude Code drops a window from the status line once it has reset.
    let hasNoFiveHourLimit: Bool
    /// Per-model windows on top of the two above. Only Claude's network source reports
    /// them; with any, the dashboard stacks the meters one per row.
    let scoped: [ScopedWindow]
    /// How many days the long window (`sevenDay`) spans, when it is not a week: Codex
    /// Free has a 30-day window instead. `nil` means 7, so snapshots stored before this
    /// field still read as weekly.
    let longWindowDays: Int?

    /// A prepaid balance instead of windows: services billed per token (DeepSeek) have
    /// no rate-limit windows at all. `nil` for the others.
    let balance: Balance?

    init(
        fiveHour: LimitWindow?, sevenDay: LimitWindow?, capturedAt: Date,
        hasNoFiveHourLimit: Bool = false, scoped: [ScopedWindow] = [], longWindowDays: Int? = nil,
        balance: Balance? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.capturedAt = capturedAt
        self.hasNoFiveHourLimit = hasNoFiveHourLimit && fiveHour == nil && sevenDay != nil
        self.scoped = scoped
        self.longWindowDays = longWindowDays == 7 ? nil : longWindowDays
        self.balance = balance
    }

    /// A balance-only snapshot, as DeepSeek reports it.
    init(balance: Balance, capturedAt: Date) {
        self.init(fiveHour: nil, sevenDay: nil, capturedAt: capturedAt, balance: balance)
    }

    /// Days in the long window: 7 for a week, 30 on Codex Free.
    var longWindowSpan: Int { longWindowDays ?? 7 }

    /// Whether the long window is a week, the only one an early reset is looked for in.
    var isLongWindowWeekly: Bool { longWindowSpan == 7 }

    /// "7 DAYS" or "30 DAYS", the long meter's title.
    var longWindowTitle: String { "\(longWindowSpan) DAYS" }

    /// "7d" or "30d", the long window in the pill and the terminal.
    var longWindowLabel: String { "\(longWindowSpan)d" }

    /// This snapshot with what only the network source knows. The status line reports
    /// neither per-model windows nor a missing 5-hour limit, so a newer one keeps those
    /// of the last network read.
    func keepingLiveData(from other: LimitSnapshot) -> LimitSnapshot {
        LimitSnapshot(
            fiveHour: fiveHour, sevenDay: sevenDay, capturedAt: capturedAt,
            hasNoFiveHourLimit: hasNoFiveHourLimit || other.hasNoFiveHourLimit,
            scoped: scoped.isEmpty ? other.scoped : scoped,
            longWindowDays: longWindowDays ?? other.longWindowDays,
            balance: balance ?? other.balance
        )
    }

    /// Every reset time the snapshot reports, for the countdown ticks.
    var resetDates: [Date] {
        ([fiveHour, sevenDay] + scoped.map(\.window)).compactMap { $0?.resetsAt }
    }

    var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil && balance == nil
    }

    /// The window the pill and the traffic light follow: the 5-hour one, or the long
    /// one only when the plan has no 5-hour limit. `nil` while the 5-hour window is unknown.
    var headline: (label: String, window: LimitWindow)? {
        if let fiveHour { return ("5h", fiveHour) }
        if hasNoFiveHourLimit, let sevenDay { return (longWindowLabel, sevenDay) }
        return nil
    }
}

/// Traffic-light level of a window, by usage. On a threshold the more severe level wins:
/// Claude used 70 % (Codex left 30 %) is `warning`, used 90 % (left 10 %) is `critical`.
enum LimitLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    /// "normal", "warning" or "critical", for files other tools read.
    var name: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }

    init(usedPercent: Double) {
        if usedPercent >= 90 {
            self = .critical
        } else if usedPercent >= 70 {
            self = .warning
        } else {
            self = .normal
        }
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

    /// Traffic-light level of the headline window, or of the balance; `nil` without data.
    func level(at now: Date = Date()) -> LimitLevel? {
        if let balance = snapshot?.balance { return balance.level }
        return snapshot?.headline.map { LimitLevel(usedPercent: $0.window.displayPercent(at: now)) }
    }

    /// Builds a state from a snapshot, deciding freshness by age.
    static func from(_ snapshot: LimitSnapshot, staleAfter: TimeInterval, now: Date = Date()) -> ServiceState {
        now.timeIntervalSince(snapshot.capturedAt) > staleAfter
            ? .stale(snapshot)
            : .fresh(snapshot)
    }
}

/// Declaration order is display order: Claude, Codex, then DeepSeek, everywhere.
enum Service: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case deepseek

    /// What a service reports: rate-limit windows that reset (Claude, Codex), or a
    /// prepaid balance spent per token (DeepSeek, connected with an API key).
    enum Kind: Sendable {
        case limits
        case balance
    }

    var id: String { rawValue }

    var kind: Kind {
        switch self {
        case .claude, .codex: .limits
        case .deepseek: .balance
        }
    }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .deepseek: "DeepSeek"
        }
    }

    /// Name of the product the user connects, as shown in Settings.
    var productName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .deepseek: "DeepSeek"
        }
    }

    /// Codex is shown as remaining quota, Claude as used quota — by user preference.
    var showsRemaining: Bool {
        self == .codex
    }

    /// Short word for what the percentage means.
    var percentMeaning: String {
        showsRemaining ? "left" : "used"
    }

    /// The service's logo in the asset catalog; sources in `assets/design/`.
    var logoName: String {
        switch self {
        case .codex: "CodexLogo"
        case .claude: "ClaudeLogo"
        case .deepseek: "DeepSeekLogo"
        }
    }
}

/// A prepaid API balance and what Limita worked out from its own history of readings:
/// DeepSeek reports only the balance, so spending and the forecast are Limita's.
struct Balance: Codable, Sendable, Equatable {
    /// A balance in a currency other than the main one.
    struct Amount: Codable, Sendable, Equatable {
        let currency: String
        let total: Double
    }

    /// "CNY" or "USD".
    let currency: String
    /// Everything that can be spent: `granted + toppedUp`.
    let total: Double
    /// Granted (bonus) money that has not expired.
    let granted: Double
    /// Money the user paid in.
    let toppedUp: Double
    /// Whether the balance still covers API calls; DeepSeek rejects them once it is out.
    let isAvailable: Bool
    var others: [Amount] = []

    /// Spent since local midnight and since the 1st of the month, by Limita's history.
    var spentToday: Double?
    var spentThisMonth: Double?
    /// Average spend per day over the last week; `nil` until a day of history exists.
    var dailyBurn: Double?
    /// The bar's full width: the balance right after the last top-up.
    var fullScale: Double?
    /// Below this the balance counts as low: the dot turns red and a notification fires.
    var lowThreshold: Double?

    /// How full the bar is, 0...1; `nil` without a full scale.
    var fraction: Double? {
        guard let fullScale, fullScale > 0 else { return nil }
        return min(max(total / fullScale, 0), 1)
    }

    /// Days the balance lasts at the current pace.
    var daysLeft: Double? {
        guard let dailyBurn, dailyBurn > 0 else { return nil }
        return max(total, 0) / dailyBurn
    }

    /// Whether the balance is at or below the user's threshold.
    var isLow: Bool {
        guard let lowThreshold, lowThreshold > 0 else { return false }
        return total <= lowThreshold
    }

    /// Red when calls are rejected or the balance is at the threshold, yellow within
    /// twice the threshold. Without a threshold, by how much of the last top-up is left.
    var level: LimitLevel {
        if !isAvailable || total <= 0 { return .critical }
        if let lowThreshold, lowThreshold > 0 {
            if total <= lowThreshold { return .critical }
            return total <= 2 * lowThreshold ? .warning : .normal
        }
        guard let fraction else { return .normal }
        return LimitLevel(usedPercent: (1 - fraction) * 100)
    }

    /// "¥110.00", "$4.20", or "EUR 3.00" for a currency without a symbol here.
    static func format(_ amount: Double, currency: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)).locale(.english))
        switch currency.uppercased() {
        case "CNY", "RMB": return "¥" + number
        case "USD": return "$" + number
        default: return "\(currency) " + number
        }
    }

    func format(_ amount: Double) -> String {
        Self.format(amount, currency: currency)
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
    /// The subscription, e.g. "Ultra" or "Pro 100", shown after the service's name.
    var plan: String?

    var isEmpty: Bool {
        limitResets == nil && codexCredits == nil && !codexCreditsUnlimited
            && claudeUsageCredits == nil && cloudCredits == nil && plan == nil
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

extension Date {
    /// "in 3 hours" / "3 hours ago", measured from `now` rather than the wall clock, so
    /// it agrees with the rest of a view rendered for `now` (and is testable).
    func relativeText(to now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .english
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: now)
    }
}
