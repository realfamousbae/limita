import Foundation

/// A limit reset worth telling the user about: one a service gave everyone (from a
/// public tracker) or one Limita noticed in the user's own numbers.
struct ResetEvent: Codable, Sendable, Equatable {
    enum Kind: Codable, Sendable, Equatable {
        /// Limits reset for everyone in `scope`.
        case global
        /// A reset to apply whenever the user likes, until `usableUntil`.
        case banked(usableUntil: Date?)
        /// The user's weekly window started over before its scheduled reset.
        case earlyWeekly
        /// Codex granted a limit reset to redeem; `count` is how many there are now.
        case newBankedCredit(count: Int)
    }

    /// Where the event came from. The public trackers ask for a visible credit.
    enum Source: String, Codable, Sendable {
        case codexReset
        case claudeResets
        case local

        /// "DATA: CODEX-RESET.COM", shown under every line that uses the tracker's data.
        var credit: String? {
            switch self {
            case .codexReset: "DATA: CODEX-RESET.COM"
            case .claudeResets: "DATA: CLAUDE-RESETS.COM"
            case .local: nil
            }
        }

        var site: URL? {
            switch self {
            case .codexReset: URL(string: "https://codex-reset.com")
            case .claudeResets: URL(string: "https://claude-resets.com")
            case .local: nil
            }
        }
    }

    /// Stable across fetches, so one event is announced once.
    let id: String
    let service: Service
    let kind: Kind
    let date: Date
    /// The announcement, e.g. a post on X.
    var url: URL? = nil
    /// Who it applies to as the tracker says it, e.g. "all" or "Pro, Max + Team".
    var scope: String? = nil
    /// The tracker's one-line description.
    var note: String? = nil
    let source: Source
    /// Not yet confirmed by the tracker: shown, but not announced.
    var isProvisional = false

    /// Lines stay up for a week, banked resets for as long as they can be applied.
    static let shownFor: TimeInterval = 7 * 24 * 60 * 60

    func isShown(at now: Date = Date()) -> Bool {
        if case .banked(let until?) = kind { return now < until }
        return now.timeIntervalSince(date) < Self.shownFor
    }

    /// "RESET FOR EVERYONE · 5 HOURS AGO", in the dashboard's caption style.
    func title(at now: Date = Date()) -> String {
        let ago = min(date, now).relativeText(to: now).uppercased()
        switch kind {
        case .global:
            return "RESET FOR \(audience) · \(ago)"
        case .banked(let until?):
            return "BANKED RESET · USE BY \(Self.dayFormatter.string(from: until).uppercased())"
        case .banked(nil):
            return "BANKED RESET · \(ago)"
        case .earlyWeekly:
            return "YOUR WEEKLY LIMIT WAS RESET EARLY · \(ago)"
        case .newBankedCredit(let count):
            return "NEW LIMIT RESET TO REDEEM · \(count) IN TOTAL"
        }
    }

    /// "EVERYONE" for "all" or no scope, otherwise the scope, e.g. "MAX".
    private var audience: String {
        guard let scope, !scope.isEmpty, scope.lowercased() != "all" else { return "EVERYONE" }
        return scope.uppercased()
    }

    /// The notification's title and body.
    var notificationTitle: String {
        switch kind {
        case .global: "\(service.displayName) limits were reset for \(audience == "EVERYONE" ? "everyone" : scope ?? "")"
        case .banked: "\(service.displayName) gave a banked limit reset"
        case .earlyWeekly: "Your \(service.displayName) weekly limit was reset early"
        case .newBankedCredit: "You have a new Codex limit reset"
        }
    }

    var notificationBody: String {
        var lines: [String] = []
        if let note { lines.append(note) }
        if case .banked(let until?) = kind { lines.append("Use it by \(Self.dayFormatter.string(from: until)).") }
        if case .newBankedCredit(let count) = kind { lines.append("\(count) available to redeem.") }
        if let site = source.site?.host { lines.append("Data: \(site)") }
        return lines.joined(separator: "\n")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .english
        formatter.dateFormat = "MMM d"
        // Deadlines are announced as "until October 22", i.e. 23:59:59 UTC; read in
        // the user's zone that could be the 23rd.
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

extension Service: Codable {}
