import Foundation

/// Limita's own record of a prepaid balance over time. DeepSeek reports only the
/// balance, so what was spent today, the pace and how long the money lasts are worked
/// out from how the balance moved between readings.
///
/// - A drop is spending, dated by the reading that saw it: a drop that happened while
///   Limita was not running lands on the first reading after.
/// - A rise is a top-up; the balance right after the last one is the bar's full width.
/// - Granted (bonus) money that expires also lowers the balance; DeepSeek does not say
///   which is which, so it counts as spending.
///
/// Readings are kept only when the balance changed, one per hour after a day and for
/// 90 days, in `deepseek-balance.json` next to the other files Limita writes.
struct BalanceLedger {
    struct Sample: Codable, Equatable, Sendable {
        let date: Date
        let total: Double
    }

    /// What the history says, for `Balance`'s derived fields.
    struct Summary: Equatable, Sendable {
        var spentToday: Double?
        var spentThisMonth: Double?
        var dailyBurn: Double?
        var fullScale: Double?
    }

    struct Stored: Codable, Equatable {
        /// The currency the samples are in; another one starts the history over.
        var currency: String?
        var samples: [Sample] = []
        /// A low-balance notification went out and the balance has not recovered since.
        var alertedLow = false
        /// A "calls are rejected" notification went out and calls work again since.
        var alertedUnavailable = false
    }

    static let keepFor: TimeInterval = 90 * 24 * 60 * 60
    /// How much history the pace needs before it is shown.
    static let minimumHistory: TimeInterval = 24 * 60 * 60

    let url: URL?
    private(set) var stored: Stored

    static var defaultURL: URL {
        ClaudeStatusCache.fileURL.deletingLastPathComponent().appendingPathComponent("deepseek-balance.json")
    }

    /// `url: nil` keeps the history in memory only, for tests.
    init(url: URL? = BalanceLedger.defaultURL) {
        self.url = url
        let data = url.flatMap { try? Data(contentsOf: $0) }
        stored = data.flatMap { try? Self.decoder.decode(Stored.self, from: $0) } ?? Stored()
    }

    var samples: [Sample] { stored.samples }

    var alertedLow: Bool {
        get { stored.alertedLow }
        set { guard newValue != stored.alertedLow else { return }; stored.alertedLow = newValue; save() }
    }

    var alertedUnavailable: Bool {
        get { stored.alertedUnavailable }
        set { guard newValue != stored.alertedUnavailable else { return }; stored.alertedUnavailable = newValue; save() }
    }

    /// Adds a reading and returns what the history now says.
    mutating func record(total: Double, currency: String, at date: Date, calendar: Calendar = .current) -> Summary {
        var next = stored
        if next.currency != currency {
            next = Stored(currency: currency, samples: [], alertedLow: stored.alertedLow, alertedUnavailable: stored.alertedUnavailable)
        }
        // An older reading (a slow request finishing late) must not reorder the history.
        if let last = next.samples.last, date < last.date {
            return Self.summarize(next.samples, now: date, calendar: calendar)
        }
        if next.samples.last?.total != total {
            next.samples.append(Sample(date: date, total: total))
        }
        next.samples = Self.compacted(next.samples, now: date)
        if next != stored {
            stored = next
            save()
        }
        return Self.summarize(stored.samples, now: date, calendar: calendar)
    }

    /// Forgets everything, for a disconnected or replaced key.
    mutating func clear() {
        stored = Stored()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Pure parts

    /// Spending today and this month, the average daily spend over the last week, and
    /// the balance right after the last top-up (or the highest seen, without one).
    static func summarize(_ samples: [Sample], now: Date, calendar: Calendar = .current) -> Summary {
        guard let first = samples.first else { return Summary() }
        let startOfDay = calendar.startOfDay(for: now)
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfDay
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)

        var today = 0.0
        var month = 0.0
        var week = 0.0
        var fullScale = samples.map(\.total).max()
        for (previous, sample) in zip(samples, samples.dropFirst()) {
            let delta = sample.total - previous.total
            if delta > 0 {
                fullScale = sample.total
            } else if delta < 0 {
                let spent = -delta
                if sample.date >= startOfDay { today += spent }
                if sample.date >= startOfMonth { month += spent }
                if sample.date >= weekAgo { week += spent }
            }
        }

        let covered = now.timeIntervalSince(first.date)
        var dailyBurn: Double?
        if covered >= minimumHistory {
            let span = now.timeIntervalSince(max(first.date, weekAgo))
            dailyBurn = week / (span / (24 * 60 * 60))
        }
        // Spending is only known for the part of the day and month history covers.
        return Summary(
            spentToday: today,
            spentThisMonth: month,
            dailyBurn: dailyBurn,
            fullScale: fullScale
        )
    }

    /// Drops samples older than `keepFor` and keeps one per hour (the hour's last)
    /// among those older than a day. The newest sample is always kept.
    static func compacted(_ samples: [Sample], now: Date) -> [Sample] {
        let cutoff = now.addingTimeInterval(-keepFor)
        let dayAgo = now.addingTimeInterval(-24 * 60 * 60)
        var result: [Sample] = []
        for sample in samples where sample.date >= cutoff {
            if let last = result.last, last.date < dayAgo, sample.date < dayAgo,
               Int(last.date.timeIntervalSince1970 / 3600) == Int(sample.date.timeIntervalSince1970 / 3600) {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
            }
        }
        return result
    }

    // MARK: - File

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension Balance {
    /// This balance with what the history says and the user's threshold.
    func with(_ summary: BalanceLedger.Summary, lowThreshold: Double?) -> Balance {
        var balance = self
        balance.spentToday = summary.spentToday
        balance.spentThisMonth = summary.spentThisMonth
        balance.dailyBurn = summary.dailyBurn
        balance.fullScale = summary.fullScale.map { max($0, total) }
        balance.lowThreshold = lowThreshold
        return balance
    }
}
