import SwiftUI

/// The dashboard: one column per connected service, or a prompt to connect one.
struct ExpandedView: View {
    let store: LimitsStore

    static let columnPadding: CGFloat = 18
    static let meterSpacing: CGFloat = 10
    /// Both meters share one width: that of the longest reset caption, so the countdown
    /// always fits on one line and the bars are the same length.
    static let meterWidth: CGFloat = {
        let caption = NSAttributedString(
            string: LimitWindow.longestResetText.uppercased(),
            attributes: [.font: AppFont.ns(DashboardStyle.captionSize), .kern: DashboardStyle.captionTracking]
        )
        return ceil(caption.size().width) + 4
    }()

    var body: some View {
        // Countdowns, "UPDATED …" and expired windows must advance between data refreshes.
        TimelineView(ResetTicks(resets: resetDates)) { context in
            VStack(spacing: 0) {
                header

                divider.frame(height: 1).padding(.horizontal, 18)

                if store.enabledServices.isEmpty {
                    ConnectPrompt(store: store)
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(store.enabledServices.enumerated()), id: \.element) { index, service in
                            if index > 0 {
                                divider.frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 14)
                            }
                            serviceDashboard(service, state: store.state(for: service), now: context.date)
                        }
                    }
                    // Columns and the divider take the height of the tallest column.
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !store.showsMenuBarIcon {
                    hiddenIconTip
                }
            }
        }
        // Height follows the content; the panel controller sizes the window to it.
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: DashboardStyle.cornerRadius, style: .continuous).fill(Color.black))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardStyle.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var resetDates: [Date] {
        store.enabledServices.flatMap { service -> [Date] in
            guard let snapshot = store.state(for: service).snapshot else { return [] }
            return [snapshot.fiveHour?.resetsAt, snapshot.sevenDay?.resetsAt].compactMap { $0 }
        }
    }

    /// The menu (Connect, Disconnect, Quit) lives on the menu-bar icon.
    private var hiddenIconTip: some View {
        VStack(spacing: 0) {
            divider.frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text("MENU BAR ICON IS HIDDEN. SHOW IT WITH THE BUTTON ABOVE TO CONNECT OR DISCONNECT SERVICES, OR TO QUIT LIMITA.")
                    .font(.app(DashboardStyle.captionSize))
                    .tracking(DashboardStyle.captionTracking)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DashboardStyle.caption)
            .padding(.vertical, 11)
        }
        .padding(.horizontal, Self.columnPadding)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08))
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                Image("StatusIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 16, height: 16)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("LIMITA")
                    .font(.app(13))
                    .tracking(1.2)
                Text("AI USAGE MONITOR")
                    .caption()
            }

            Spacer()

            Button {
                store.showsMenuBarIcon.toggle()
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.08))
                    MenuBarIconGlyph(crossedOut: store.showsMenuBarIcon)
                }
                .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.showsMenuBarIcon ? "Hide menu bar icon" : "Show menu bar icon")

            if !store.enabledServices.isEmpty {
                Button {
                    store.refresh(live: true)
                } label: {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.08))
                        if store.isRefreshing {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .frame(width: 27, height: 27)
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .accessibilityLabel("Refresh")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    // MARK: - Service column

    private func serviceDashboard(_ service: Service, state: ServiceState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ServiceBadge(service: service)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(service.displayName)
                            .font(.app(14))
                        LevelDot(state: state, now: now)
                    }
                    // Codex has no status line: its meters already say "left", and
                    // staleness still shows as dimmed numbers and "UPDATED …".
                    if service == .claude {
                        Text("\(statusLabel(state)) · SHOWING \(service.percentMeaning.uppercased())")
                            .caption()
                    }
                }
                Spacer(minLength: 0)
            }
            // Same height with or without the status line, so both columns' meters line up.
            .frame(height: 36)

            if let message = store.setupMessage, message.service == service {
                SetupMessage(text: message.text) { store.setupMessage = nil }
            } else if let snapshot = state.snapshot {
                HStack(spacing: Self.meterSpacing) {
                    Group {
                        if snapshot.hasNoFiveHourLimit {
                            unlimitedMetric("5 HOURS")
                        } else {
                            metric("5 HOURS", service: service, window: snapshot.fiveHour,
                                   color: DashboardStyle.fiveHourBar(for: service), stale: state.isStale, now: now)
                        }
                    }
                    .frame(width: Self.meterWidth)
                    metric("7 DAYS", service: service, window: snapshot.sevenDay,
                           color: DashboardStyle.accent(for: service).opacity(0.72), stale: state.isStale, now: now)
                        .frame(width: Self.meterWidth)
                }

                detailRows(for: service)

                Text("UPDATED \(Self.updatedText(snapshot.capturedAt, now: now).uppercased())")
                    .caption(faint: true)
                    .lineLimit(1)

                if let error = store.liveErrors[service] {
                    ErrorLine(text: error)
                }
            } else {
                Text(store.liveErrors[service] ?? state.unavailableReason ?? "No data")
                    .font(.app(DashboardStyle.valueSize))
                    .foregroundStyle(DashboardStyle.caption)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Self.columnPadding)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "just now" for fresh data. The timeline tick can predate a just-fetched snapshot,
    /// which would otherwise read "in 0 seconds".
    static func updatedText(_ capturedAt: Date, now: Date) -> String {
        now.timeIntervalSince(capturedAt) < 10 ? "just now" : capturedAt.relativeText(to: now)
    }

    private func statusLabel(_ state: ServiceState) -> String {
        if state.snapshot == nil { return "NO DATA" }
        return state.isStale ? "STALE DATA" : "LIVE DATA"
    }

    /// One window's meter. The number and bar show what `service` is displayed as (left
    /// or used). The number stays white; the bar's colour follows usage, so red still
    /// means "almost out". Stale numbers are dimmed so they don't read as current.
    private func metric(
        _ title: String, service: Service, window: LimitWindow?, color: Color, stale: Bool, now: Date
    ) -> some View {
        let used = window?.displayFraction(at: now) ?? 0
        let shown = (window?.shownPercent(for: service, at: now) ?? 0) / 100
        return VStack(alignment: .leading, spacing: 5) {
            Text("\(title) \(service.percentMeaning.uppercased())")
                .caption()

            Text(window?.shownText(for: service, at: now) ?? "—")
                .font(.app(24))
                .monospacedDigit()
                .opacity(stale ? 0.55 : 1)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule()
                        .fill(DashboardStyle.pressureColor(used, fallback: color))
                        .frame(width: geometry.size.width * shown)
                        .opacity(stale ? 0.55 : 1)
                }
            }
            .frame(height: 4)

            Text(window?.resetText(at: now)?.uppercased() ?? "NO WINDOW")
                .caption()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Stands in for the 5-hour meter when the plan has no 5-hour limit.
    private func unlimitedMetric(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .caption()
            Text("∞")
                .font(.app(24))
            Capsule().fill(Color.white.opacity(0.09))
                .frame(height: 4)
            Text("NO 5-HOUR LIMIT")
                .caption()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Balances

    /// Rows under the meters. A row is hidden when the service did not report its value.
    @ViewBuilder
    private func detailRows(for service: Service) -> some View {
        let rows = Self.detailRows(for: service, details: store.details[service] ?? AccountDetails())
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows, id: \.label) { row in
                    HStack(spacing: 6) {
                        Text(row.label)
                            .caption()
                        Spacer(minLength: 4)
                        Text(row.value)
                            .font(.app(DashboardStyle.valueSize))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
    }

    struct DetailRow: Equatable {
        let label: String
        let value: String
    }

    static func detailRows(for service: Service, details: AccountDetails) -> [DetailRow] {
        var rows: [DetailRow] = []
        if let resets = details.limitResets {
            rows.append(DetailRow(label: "LIMIT RESETS", value: "\(resets)"))
        }
        switch service {
        case .codex:
            if details.codexCreditsUnlimited {
                rows.append(DetailRow(label: "CREDITS", value: "Unlimited"))
            } else if let credits = details.codexCredits {
                let dollars = credits / AccountDetails.codexCreditsPerDollar
                rows.append(DetailRow(
                    label: "CREDITS",
                    value: "\(credits.formatted(.number.precision(.fractionLength(0...2)).locale(.english))) credits · \(usd(dollars))"
                ))
            }
        case .claude:
            switch details.claudeUsageCredits {
            case .off:
                rows.append(DetailRow(label: "USAGE CREDITS", value: "Off"))
            case .balance(let dollars):
                rows.append(DetailRow(label: "USAGE CREDITS", value: usd(dollars)))
            case .spent(let dollars, let limit):
                rows.append(DetailRow(
                    label: "USAGE CREDITS",
                    value: limit.map { "\(usd(dollars)) of \(usd($0)) used" } ?? "\(usd(dollars)) used"
                ))
            case nil:
                break
            }
            if let cloud = details.cloudCredits {
                var value = usd(cloud.remaining)
                if let limit = cloud.limit { value += " / \(usd(limit))" }
                rows.append(DetailRow(label: "CLOUD CREDITS", value: value))
            }
        }
        return rows
    }

    private static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(.english))
    }
}

// MARK: - Pieces

/// The app glyph on the menu-bar toggle: crossed out while the icon is shown (the button
/// hides it), plain while it is hidden (the button brings it back).
struct MenuBarIconGlyph: View {
    let crossedOut: Bool

    var body: some View {
        ZStack {
            Image("StatusIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 13, height: 13)
            if crossedOut {
                // The dark rim cuts the glyph so the slash reads at this size.
                Capsule()
                    .fill(Color(white: 0.08))
                    .frame(width: 4, height: 19)
                    .rotationEffect(.degrees(-45))
                Capsule()
                    .fill(Color.white)
                    .frame(width: 1.6, height: 18)
                    .rotationEffect(.degrees(-45))
            }
        }
    }
}

/// Redraws when a countdown's minute changes and every 30 s for "UPDATED …", instead of
/// polling every second. `durationText` rounds up, so a countdown to `reset` changes at
/// `reset` minus whole minutes.
struct ResetTicks: TimelineSchedule {
    let resets: [Date]
    var interval: TimeInterval = 30

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        AnySequence(sequence(first: startDate) { next(after: $0) })
    }

    func next(after date: Date) -> Date {
        var next = date.addingTimeInterval(interval)
        for reset in resets where reset > date {
            let minutes = (reset.timeIntervalSince(date) / 60).rounded(.down)
            var tick = reset.addingTimeInterval(-minutes * 60)
            if tick <= date { tick = tick.addingTimeInterval(60) }
            next = min(next, tick)
        }
        return next
    }
}

/// Traffic light for a service's headline window. Stale data keeps its colour, dimmed;
/// no data is grey.
struct LevelDot: View {
    let state: ServiceState
    let now: Date

    var body: some View {
        Circle()
            .fill(DashboardStyle.levelColor(state.level(at: now)))
            .opacity(state.isStale ? 0.4 : 1)
            .frame(width: 6, height: 6)
    }
}

struct ServiceBadge: View {
    let service: Service
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DashboardStyle.accent(for: service).opacity(0.14))
            Image(systemName: service.symbolName)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(DashboardStyle.accent(for: service))
        }
        .frame(width: size, height: size)
    }
}

/// Why the last live fetch failed, shown inline: tooltips never appear in a panel that
/// does not activate the app.
private struct ErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(text)
                .font(.app(DashboardStyle.captionSize))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.yellow.opacity(0.9))
    }
}

private struct SetupMessage: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.app(DashboardStyle.valueSize))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(6)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK", action: dismiss)
                .buttonStyle(.plain)
                .font(.app(DashboardStyle.captionSize))
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
    }
}

/// Shown when no service is connected.
private struct ConnectPrompt: View {
    let store: LimitsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect a service to see its limits.")
                .font(.app(DashboardStyle.valueSize))
                .foregroundStyle(.white.opacity(0.8))
            ForEach(Service.allCases) { service in
                Button {
                    store.connect(service)
                } label: {
                    HStack(spacing: 10) {
                        ServiceBadge(service: service, size: 26)
                        Text("Connect \(service.productName)")
                            .font(.app(DashboardStyle.valueSize))
                        Spacer(minLength: 0)
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Style

enum DashboardStyle {
    static let healthy = Color(red: 0.32, green: 0.92, blue: 0.58)
    static let cornerRadius: CGFloat = 20

    /// Small uppercase labels. Sized and tinted for ~4.5:1 contrast on black.
    static let captionSize: CGFloat = 9.5
    static let caption = Color.white.opacity(0.62)
    /// The least important line, e.g. "UPDATED …".
    static let faintCaption = Color.white.opacity(0.48)
    static let captionTracking: CGFloat = 0.3
    /// Values next to captions, e.g. balances.
    static let valueSize: CGFloat = 11

    static func accent(for service: Service) -> Color {
        service == .codex
            ? Color(red: 0.31, green: 0.67, blue: 1)
            : Color(red: 1, green: 0.58, blue: 0.30)
    }

    /// Claude's two bars share the softer weekly tone; Codex keeps a brighter 5-hour bar.
    static func fiveHourBar(for service: Service) -> Color {
        service == .claude ? accent(for: service).opacity(0.72) : accent(for: service)
    }

    /// Orange from 70 %, red from 90 %.
    static func pressureColor(_ fraction: Double, fallback: Color) -> Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return fallback
    }

    static func levelColor(_ level: LimitLevel?) -> Color {
        switch level {
        case .normal: healthy
        case .warning: .yellow
        case .critical: .red
        case nil: .white.opacity(0.32)
        }
    }
}

extension Text {
    /// The shared caption style for small labels.
    func caption(faint: Bool = false) -> some View {
        font(.app(DashboardStyle.captionSize))
            .tracking(DashboardStyle.captionTracking)
            .foregroundStyle(faint ? DashboardStyle.faintCaption : DashboardStyle.caption)
    }
}
