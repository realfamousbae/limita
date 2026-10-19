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

/// The GitHub-style grid: one column per week, Sunday on top, the newest week on the
/// right. Built for a given `today`, so it is testable.
struct ActivityGrid: Equatable {
    static let weeks = 53

    struct Day: Equatable {
        let key: DayKey
        let date: Date
        let tokens: Int
        /// 0 for no activity, 1...4 for the four shades.
        let level: Int
    }

    struct MonthLabel: Equatable {
        let column: Int
        let text: String
    }

    /// `columns[week][weekday]`; `nil` for the days after today in the last week.
    let columns: [[Day?]]
    let months: [MonthLabel]
    /// Tokens over every day in the grid.
    let total: Int

    init(days: [DayKey: Int], today: Date = Date(), calendar: Calendar = .activity) {
        let formatter = DayKeys.formatter(timeZone: calendar.timeZone)
        let today = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: today) - calendar.firstWeekday
        let thisWeek = calendar.date(byAdding: .day, value: -((weekday + 7) % 7), to: today)!
        let first = calendar.date(byAdding: .weekOfYear, value: -(Self.weeks - 1), to: thisWeek)!

        var dates: [[Date?]] = []
        for week in 0..<Self.weeks {
            dates.append((0..<7).map { day in
                let date = calendar.date(byAdding: .day, value: week * 7 + day, to: first)!
                return date <= today ? date : nil
            })
        }
        let values = dates.joined().compactMap { $0.map { days[formatter.string(from: $0)] ?? 0 } }
        let active = values.filter { $0 > 0 }
        columns = dates.map { week in
            week.map { date in
                date.map { date in
                    let key = formatter.string(from: date)
                    let tokens = days[key] ?? 0
                    return Day(key: key, date: date, tokens: tokens, level: Self.level(tokens, active: active))
                }
            }
        }
        total = values.reduce(0, +)
        months = Self.monthLabels(columns: dates.map { $0[0]! }, calendar: calendar)
    }

    // MARK: - Shades

    /// A day's shade is the share of active days with as many tokens or fewer, in
    /// quarters: the busiest day is always the darkest, and one huge day does not wash
    /// out the rest. The same rule as `activity.rs` on Windows.
    static func level(_ tokens: Int, active: [Int]) -> Int {
        guard tokens > 0, !active.isEmpty else { return 0 }
        let atMost = active.filter { $0 <= tokens }.count
        return max(1, (4 * atMost + active.count - 1) / active.count)
    }

    // MARK: - Months

    /// A label over the first week that starts in a new month. The first one is left out
    /// when the next is too close for both to fit.
    private static func monthLabels(columns: [Date], calendar: Calendar) -> [MonthLabel] {
        let formatter = DateFormatter()
        formatter.locale = .english
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM"

        var labels: [MonthLabel] = []
        var previous: Int?
        for (index, start) in columns.enumerated() {
            let month = calendar.component(.month, from: start)
            if month != previous {
                labels.append(MonthLabel(column: index, text: formatter.string(from: start)))
            }
            previous = month
        }
        if labels.count > 1, labels[1].column - labels[0].column < 3 {
            labels.removeFirst()
        }
        return labels
    }
}

extension Calendar {
    /// Weeks start on Sunday, as on GitHub, whatever the system's first weekday.
    static var activity: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
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
}
