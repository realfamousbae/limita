import Foundation
import Observation
import os

/// Keeps track of limit resets: the public trackers' latest events per service
/// (`ResetFeed`), and resets Limita notices in the user's own numbers. The dashboard
/// shows the newest of them in each column; new ones are announced through `notifier`.
///
/// What was seen is saved, so a relaunch announces nothing twice. The very first look
/// at a source only records what is there: an old reset is shown, never announced.
@Observable
@MainActor
final class ResetWatcher {
    static let pollInterval: TimeInterval = 15 * 60

    /// The weekly window as last seen, to tell an early reset from a scheduled one.
    struct WeeklyMark: Codable, Equatable, Sendable {
        let resetsAt: Date
        let usedPercent: Double
        let capturedAt: Date
    }

    /// Everything that survives a relaunch, saved as one JSON value.
    struct Memory: Codable, Equatable {
        /// The newest Codex reset seen; a forecast going back in time is a correction.
        var codexLastReset: Date?
        /// Claude event ids already recorded or announced.
        var claudeSeen: Set<String>?
        var weekly: [Service: WeeklyMark] = [:]
        var limitResets: Int?
        /// Resets noticed in the user's own numbers that are still shown, one per
        /// service and kind.
        var local: [ResetEvent] = []
    }

    static let memoryKey = "resetWatcher"
    static let notificationsKey = "resetNotificationsEnabled"

    /// The trackers' latest events per service, newest first.
    private(set) var feedEvents: [Service: [ResetEvent]] = [:]
    private(set) var memory: Memory {
        didSet { save() }
    }
    /// Whether new resets are announced. The dashboard line shows either way.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Self.notificationsKey) }
    }
    /// Services the user tracks; others are neither fetched nor announced.
    @ObservationIgnored var trackedServices: () -> [Service] = { Service.allCases }

    @ObservationIgnored private let notifier: ResetNotifying
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let feedURL: (Service) -> URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fetching: Set<Service> = []
    @ObservationIgnored private var pausedUntil: [Service: Date] = [:]
    @ObservationIgnored private var lastFetch: [Service: Date] = [:]
    @ObservationIgnored private var rateLimitStreak: [Service: Int] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.limita.app", category: "resets")

    init(
        notifier: ResetNotifying? = nil,
        defaults: UserDefaults = .standard,
        feedURL: @escaping (Service) -> URL = { ResetFeed.url(for: $0) }
    ) {
        self.notifier = notifier ?? SystemResetNotifier.shared
        self.defaults = defaults
        self.feedURL = feedURL
        memory = defaults.data(forKey: Self.memoryKey).flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } ?? Memory()
        notificationsEnabled = defaults.object(forKey: Self.notificationsKey) as? Bool ?? true
    }

    /// The line for a service's column: its newest reset still worth showing.
    func event(for service: Service, now: Date = Date()) -> ResetEvent? {
        let candidates = (feedEvents[service] ?? []) + memory.local.filter { $0.service == service }
        return candidates.filter { $0.isShown(at: now) }.max { $0.date < $1.date }
    }

    // MARK: - Trackers

    /// Fetches now and then every `pollInterval`.
    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Asks the trackers of the tracked services, except one that asked for a pause.
    func refresh(now: Date = Date()) {
        for service in trackedServices() where !fetching.contains(service) {
            if let paused = pausedUntil[service], now < paused { continue }
            // The trackers ask for at most one request a minute.
            if let last = lastFetch[service], now.timeIntervalSince(last) < 60 { continue }
            lastFetch[service] = now
            fetching.insert(service)
            let url = feedURL(service)
            Task {
                defer { fetching.remove(service) }
                do {
                    let events = try await ResetFeed.fetch(service, from: url)
                    rateLimitStreak[service] = nil
                    ingest(events, for: service)
                } catch let error as ResetFeed.RateLimited {
                    let streak = (rateLimitStreak[service] ?? 0) + 1
                    rateLimitStreak[service] = streak
                    pausedUntil[service] = now.addingTimeInterval(
                        LimitsStore.rateLimitPause(streak: streak, retryAfter: error.retryAfter)
                    )
                    log.info("\(service.rawValue, privacy: .public) reset feed rate-limited")
                } catch {
                    // Offline or the site is down: keep what is shown, try at the next tick.
                    log.info("\(service.rawValue, privacy: .public) reset feed failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Takes a tracker's events: shows them, and announces those not seen before.
    func ingest(_ events: [ResetEvent], for service: Service, now: Date = Date()) {
        feedEvents[service] = events
        switch service {
        case .codex:
            guard let latest = events.max(by: { $0.date < $1.date }) else { return }
            guard let last = memory.codexLastReset else {
                memory.codexLastReset = latest.date
                return
            }
            // Only a reset after the last one counts; an earlier date is a correction.
            guard latest.date > last else { return }
            memory.codexLastReset = latest.date
            announce(latest, now: now)
        case .claude:
            let confirmed = events.filter { !$0.isProvisional }
            guard let seen = memory.claudeSeen else {
                // Nothing to record yet; the first reset to appear is news.
                guard !confirmed.isEmpty else { return }
                memory.claudeSeen = Set(confirmed.map(\.id))
                return
            }
            let new = confirmed.filter { !seen.contains($0.id) }
            guard !new.isEmpty else { return }
            memory.claudeSeen = seen.union(new.map(\.id))
            // A batch of old events (e.g. the tracker backfilled) is recorded quietly.
            new.filter { $0.isShown(at: now) }.forEach { announce($0, now: now) }
        }
    }

    // MARK: - The user's own numbers

    /// Compares a service's numbers with the last ones seen: a weekly window that
    /// started over early, or a new Codex limit reset to redeem, is an event.
    func observe(_ service: Service, snapshot: LimitSnapshot?, details: AccountDetails?, now: Date = Date()) {
        if let weekly = snapshot?.sevenDay, let resetsAt = weekly.resetsAt, let snapshot {
            let previous = memory.weekly[service]
            // An older snapshot (e.g. a stale local file) must not overwrite a newer one.
            if previous.map({ snapshot.capturedAt >= $0.capturedAt }) ?? true {
                let current = WeeklyMark(resetsAt: resetsAt, usedPercent: weekly.usedPercent, capturedAt: snapshot.capturedAt)
                if current != previous { memory.weekly[service] = current }
                if let previous, Self.isEarlyWeeklyReset(previous: previous, current: current, now: now) {
                    record(ResetEvent(
                        id: "early-\(service.rawValue)-\(Int(resetsAt.timeIntervalSince1970))",
                        service: service, kind: .earlyWeekly, date: min(snapshot.capturedAt, now), source: .local
                    ), now: now)
                }
            }
        }

        if service == .codex, let count = details?.limitResets {
            let previous = memory.limitResets
            if count != previous { memory.limitResets = count }
            // Fewer is the user redeeming one.
            if let previous, count > previous {
                record(ResetEvent(
                    id: "credit-\(Int(now.timeIntervalSince1970))",
                    service: .codex, kind: .newBankedCredit(count: count), date: now, source: .local
                ), now: now)
            }
        }
    }

    /// The window started over well before its scheduled reset, with a lower usage.
    ///
    /// Guards against a wrong clock either way: the old reset must still be half an
    /// hour away by the current clock (so a clock that jumped forward past it reads as
    /// a scheduled reset), and the new one must not be a whole week after the old one
    /// (which is what a scheduled reset looks like to a clock running behind).
    nonisolated static func isEarlyWeeklyReset(previous: WeeklyMark, current: WeeklyMark, now: Date) -> Bool {
        let week: TimeInterval = 7 * 24 * 60 * 60
        return previous.resetsAt > now.addingTimeInterval(30 * 60)
            && current.resetsAt > previous.resetsAt.addingTimeInterval(60 * 60)
            && current.resetsAt < previous.resetsAt.addingTimeInterval(week - 30 * 60)
            && previous.usedPercent - current.usedPercent >= 5
    }

    private func record(_ event: ResetEvent, now: Date) {
        memory.local = memory.local.filter {
            $0.isShown(at: now) && !($0.service == event.service && Self.sameKind($0.kind, event.kind))
        } + [event]
        announce(event, now: now)
    }

    private func announce(_ event: ResetEvent, now: Date) {
        guard notificationsEnabled, !event.isProvisional, event.isShown(at: now),
              trackedServices().contains(event.service), !isEcho(event)
        else { return }
        notifier.notify(event)
    }

    /// A reset for everyone also restarts the user's own weekly window: whichever of
    /// the two is seen second is the same news.
    private func isEcho(_ event: ResetEvent) -> Bool {
        let window: TimeInterval = 3 * 60 * 60
        let others: [ResetEvent]
        switch event.kind {
        case .earlyWeekly: others = feedEvents[event.service] ?? []
        case .global, .banked:
            others = memory.local.filter { $0.service == event.service && $0.kind == .earlyWeekly }
        case .newBankedCredit: return false
        }
        return others.contains { abs($0.date.timeIntervalSince(event.date)) < window }
    }

    private static func sameKind(_ a: ResetEvent.Kind, _ b: ResetEvent.Kind) -> Bool {
        switch (a, b) {
        case (.global, .global), (.banked, .banked), (.earlyWeekly, .earlyWeekly), (.newBankedCredit, .newBankedCredit): true
        default: false
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        defaults.set(data, forKey: Self.memoryKey)
    }
}
