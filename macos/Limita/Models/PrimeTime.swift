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

}

/// The prime-time badge's text: whose peak hours are on and what that means.
struct PrimeTimeNotice: Equatable {
    /// The service in peak hours, in bold, when it must be told apart from the other
    /// connected services. It starts the first line.
    let strong: String?
    /// The first line after `strong`.
    let title: String
    let detail: String

    var firstLine: String { (strong ?? "") + title }

    static let detailText = "USAGE LIMITS RUN OUT FASTER"

    /// `nil` when no connected service is in peak hours. One service names itself, in
    /// bold if another service is connected; every connected service in peak hours at
    /// once reads as all providers.
    init?(active: [Service], connected: [Service]) {
        guard !active.isEmpty else { return nil }
        detail = Self.detailText
        if active.count == 1, let service = active.first {
            let name = service.displayName.uppercased()
            if connected.count > 1 {
                strong = name
                title = " PEAK HOURS"
            } else {
                strong = nil
                title = "\(name) PEAK HOURS"
            }
        } else {
            strong = nil
            title = "PEAK HOURS FOR ALL PROVIDERS"
        }
    }
}
