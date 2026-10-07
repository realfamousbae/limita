import Foundation

/// Weekly peak hours, during which a service's limits run out faster.
struct PrimeTime: Sendable, Equatable {
    let timeZone: TimeZone
    /// Calendar weekdays in `timeZone`, 1 = Sunday … 7 = Saturday.
    let weekdays: Set<Int>
    /// Minutes after midnight in `timeZone`; `end` is exclusive.
    let start: Int
    let end: Int

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func contains(_ date: Date) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, weekdays.contains(weekday),
              let hour = parts.hour, let minute = parts.minute
        else { return false }
        let minutes = hour * 60 + minute
        return minutes >= start && minutes < end
    }

    /// The next start or end time of day after `date`, so the badge appears and goes
    /// away on time. Days outside `weekdays` also count; that only costs a redraw.
    func nextChange(after date: Date) -> Date? {
        [start, end].compactMap { minutes in
            calendar.nextDate(
                after: date,
                matching: DateComponents(hour: minutes / 60, minute: minutes % 60),
                matchingPolicy: .nextTime
            )
        }.min()
    }
}

extension Service {
    /// When the service's limits run out faster; `nil` when it has no peak hours.
    var primeTime: PrimeTime? {
        switch self {
        // Anthropic, March 2026: 5-hour sessions run out faster on weekdays 5–11 AM PT.
        case .claude:
            PrimeTime(
                timeZone: TimeZone(identifier: "America/Los_Angeles")!,
                weekdays: [2, 3, 4, 5, 6],
                start: 5 * 60,
                end: 11 * 60
            )
        // Chosen by the user: weekdays 12:00–18:00 UTC.
        case .codex:
            PrimeTime(
                timeZone: TimeZone(identifier: "UTC")!,
                weekdays: [2, 3, 4, 5, 6],
                start: 12 * 60,
                end: 18 * 60
            )
        }
    }

    /// The prime-time badge's two lines.
    var primeTimeLines: (String, String) {
        ("\(displayName.uppercased()) PRIME TIME. WORK", "CAN BURN MORE TOKENS AND LIMITS")
    }
}
