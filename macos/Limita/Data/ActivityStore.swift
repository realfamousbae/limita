import Foundation
import Observation

/// The activity panel under the dashboard: whether it is open, and the tokens per day
/// it shows. Logs are scanned only while the panel is open, never on the minute timer.
@Observable
@MainActor
final class ActivityStore {
    static let expandedKey = "activityExpanded"

    /// Saved, so the dashboard opens the way the user left it.
    var isExpanded: Bool {
        didSet {
            guard isExpanded != oldValue else { return }
            defaults.set(isExpanded, forKey: Self.expandedKey)
        }
    }
    private(set) var days: [Service: [DayKey: Int]] = [:]
    /// No scan has finished yet, so there is nothing to show.
    var isLoaded: Bool { lastScan != nil }

    @ObservationIgnored private let reader: ActivityReader
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastScan: Date?
    @ObservationIgnored private var isScanning = false

    init(reader: ActivityReader = ActivityReader(), defaults: UserDefaults = .standard) {
        self.reader = reader
        self.defaults = defaults
        isExpanded = defaults.bool(forKey: Self.expandedKey)
    }

    /// Rescans unless that happened within `maxAge`. Unchanged files are not re-read, so
    /// a rescan is cheap after the first.
    func refresh(_ services: [Service], ifOlderThan maxAge: TimeInterval = 0) {
        guard isExpanded, !isScanning, !services.isEmpty else { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < maxAge { return }
        isScanning = true
        let reader = reader
        Task {
            let result = await Task.detached(priority: .utility) { reader.read(services) }.value
            days.merge(result) { _, new in new }
            lastScan = Date()
            isScanning = false
        }
    }
}
