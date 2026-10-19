import Foundation

/// A local calendar day, "2026-10-16". Keys of the activity history; the same format
/// on Windows, so `activity.json` reads the same everywhere.
typealias DayKey = String

enum DayKeys {
    /// Gregorian with POSIX digits whatever the system settings; local time zone, so a
    /// day is the user's day, not UTC's.
    static func formatter(timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// What the activity panel shows: the last week, the last month, or everything saved
/// up to half a year.
enum ActivityPeriod: String, CaseIterable, Sendable {
    case week, month, all

    var title: String {
        switch self {
        case .week: "WEEK"
        case .month: "MONTH"
        case .all: "ALL"
        }
    }
}

/// One service's graph and summary for a period, built for a given `today` so it is
/// testable. Weeks start on Monday.
///
/// - week: the last 7 days in one row.
/// - month: the last 5 weeks as a calendar, a row per week.
/// - all: a column per week, Monday on top, from the first saved day (at least 18 weeks
///   back) to today, at most 26 weeks.
struct ActivityGrid: Equatable {
    static let maxWeeks = 26
    /// Enough weeks to fill a column, however short the history.
    static let minWeeks = 18

    enum Layout: Equatable {
        case row, calendar, weeks
    }

    struct Day: Equatable {
        let key: DayKey
        let date: Date
        let tokens: Int
        /// 0 for no activity, 1...4 for the four shades.
        let level: Int
    }

    let layout: Layout
    /// `cells[row][column]`; `nil` where a day is outside the period (after today).
    let cells: [[Day?]]
    /// Over each column: weekday names, or the month where a week starts one.
    let columnLabels: [String?]
    /// Left of each row: Mon, Wed and Fri in the week layout; nil otherwise.
    let rowLabels: [String?]
    let summary: ActivitySummary

    var rows: Int { cells.count }
    var columns: Int { cells.first?.count ?? 0 }

    init(days: [DayKey: DayStats], period: ActivityPeriod, today: Date = Date(), calendar: Calendar = .activity) {
        let formatter = DayKeys.formatter(timeZone: calendar.timeZone)
        let today = calendar.startOfDay(for: today)
        func shift(_ date: Date, _ days: Int) -> Date {
            calendar.date(byAdding: .day, value: days, to: date)!
        }
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7 // Monday = 0
        let thisMonday = shift(today, -weekday)

        // Dates laid out as rows of columns; nil after today.
        let dates: [[Date?]]
        switch period {
        case .week:
            layout = .row
            dates = [(0..<7).map { shift(today, $0 - 6) }]
        case .month:
            layout = .calendar
            dates = (0..<5).map { week in
                (0..<7).map { day in
                    let date = shift(thisMonday, (week - 4) * 7 + day)
                    return date <= today ? date : nil
                }
            }
        case .all:
            layout = .weeks
            let first = days.filter { $0.value.isActive }.keys.min().flatMap { formatter.date(from: $0) } ?? today
            let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: thisMonday).day ?? 0
            let weeks = min(max((span + 6) / 7 + 1, Self.minWeeks), Self.maxWeeks)
            dates = (0..<7).map { day in
                (0..<weeks).map { week in
                    let date = shift(thisMonday, (week - weeks + 1) * 7 + day)
                    return date <= today ? date : nil
                }
            }
        }

        let keyed = dates.joined().compactMap { $0 }.map { ($0, formatter.string(from: $0)) }
        let active = keyed.map { days[$0.1]?.tokens ?? 0 }.filter { $0 > 0 }
        var byDate: [Date: Day] = [:]
        for (date, key) in keyed {
            let tokens = days[key]?.tokens ?? 0
            byDate[date] = Day(key: key, date: date, tokens: tokens, level: Self.level(tokens, active: active))
        }
        cells = dates.map { row in row.map { $0.flatMap { byDate[$0] } } }

        let english = DateFormatter()
        english.locale = .english
        english.calendar = calendar
        english.timeZone = calendar.timeZone
        switch period {
        case .week:
            english.dateFormat = "EEE d"
            columnLabels = dates[0].map { $0.map { english.string(from: $0) } }
            rowLabels = [nil]
        case .month:
            columnLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            rowLabels = Array(repeating: nil, count: 5)
        case .all:
            english.dateFormat = "MMM"
            columnLabels = Self.monthLabels(mondays: dates[0].map { $0! }, calendar: calendar, formatter: english)
            rowLabels = ["Mon", nil, "Wed", nil, "Fri", nil, nil]
        }

        summary = ActivitySummary(days: days, keys: keyed.map(\.1))
    }

    /// A day's shade is the share of active days with as many tokens or fewer, in
    /// quarters: the busiest day is always the darkest, and one huge day does not wash
    /// out the rest. The same rule as `activity.rs` on Windows.
    static func level(_ tokens: Int, active: [Int]) -> Int {
        guard tokens > 0, !active.isEmpty else { return 0 }
        let atMost = active.filter { $0 <= tokens }.count
        return max(1, (4 * atMost + active.count - 1) / active.count)
    }

    /// The month over the first week that starts in it. The first label is left out
    /// when the next is too close for both to fit.
    private static func monthLabels(mondays: [Date], calendar: Calendar, formatter: DateFormatter) -> [String?] {
        var labels: [String?] = Array(repeating: nil, count: mondays.count)
        var previous: Int?
        var placed: [Int] = []
        for (index, monday) in mondays.enumerated() {
            let month = calendar.component(.month, from: monday)
            if month != previous {
                labels[index] = formatter.string(from: monday)
                placed.append(index)
            }
            previous = month
        }
        if placed.count > 1, placed[1] - placed[0] < 3 {
            labels[placed[0]] = nil
        }
        return labels
    }
}

/// The few numbers over the graph, for the days the period shows.
struct ActivitySummary: Equatable {
    let tokens: Int
    let usage: TokenUsage
    /// Model with the most tokens, as shown ("Opus 5.5"); nil without any.
    let favoriteModel: String?
    let messages: Int
    /// The local hour with the most messages; nil without any.
    let peakHour: Int?

    init(days: [DayKey: DayStats], keys: [DayKey]) {
        let shown = keys.compactMap { days[$0] }
        tokens = shown.reduce(0) { $0 + $1.tokens }
        usage = TokenUsage(
            input: shown.reduce(0) { $0 + $1.input },
            output: shown.reduce(0) { $0 + $1.output },
            cacheWrite: shown.reduce(0) { $0 + $1.cacheWrite },
            cacheRead: shown.reduce(0) { $0 + $1.cacheRead }
        )
        messages = shown.reduce(0) { $0 + $1.messages }

        var models: [String: Int] = [:]
        for day in shown { models.merge(day.models, uniquingKeysWith: +) }
        favoriteModel = models.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
            .map { Self.modelName($0.key) }

        var hours = Array(repeating: 0, count: 24)
        for day in shown { hours = zip(hours, day.hours).map(+) }
        let busiest = hours.max() ?? 0
        peakHour = busiest > 0 ? hours.firstIndex(of: busiest) : nil
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-3-5-haiku-20241022" → "Haiku 3.5";
    /// other ids as they are.
    static func modelName(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
            .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = parts.first(where: { $0.first?.isLetter == true }) else { return id }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " \(version)")
    }

    var peakHourText: String {
        peakHour.map { String(format: "%02d:00", $0) } ?? "—"
    }
}

extension Calendar {
    /// Gregorian in the local time zone; the grid lays weeks out from Monday itself.
    static var activity: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

enum TokenFormat {
    /// "950", "12.3K", "4.5M", "1.2B".
    static func compact(_ tokens: Int) -> String {
        let value = Double(tokens)
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (size, suffix) in units where value >= size {
            let scaled = value / size
            let text = scaled >= 100
                ? String(format: "%.0f", scaled)
                : String(format: "%.1f", scaled).replacingOccurrences(of: ".0", with: "")
            return text + suffix
        }
        return "\(tokens)"
    }

    /// Thousands with separators, for the chip over a hovered day: "0K", "<1K", "12,346K".
    static func thousands(_ tokens: Int) -> String {
        if tokens == 0 { return "0K" }
        if tokens < 500 { return "<1K" }
        let value = (tokens + 500) / 1000
        return value.formatted(.number.locale(.english).grouping(.automatic)) + "K"
    }

    /// "3,685".
    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(.english).grouping(.automatic))
    }
}
