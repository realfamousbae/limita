import SwiftUI

/// The dashboard: one column per connected service, or a prompt to connect one.
struct ExpandedView: View {
    let store: LimitsStore

    static let columnPadding: CGFloat = 18
    static let meterSpacing: CGFloat = 10
    /// The longest reset caption's width. A column fits two of these side by side, the
    /// grid of the tiles, which leaves each meter row room for its value and a countdown
    /// on one line.
    static let meterWidth: CGFloat = {
        let caption = NSAttributedString(
            string: LimitWindow.longestResetText.uppercased(),
            attributes: [.font: AppFont.ns(DashboardStyle.meterCaptionSize), .kern: DashboardStyle.captionTracking]
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

                    ActivityToggle(store: store)
                    // The window grows to fit, so the panel drops down below the toggle,
                    // which stays where it is.
                    if store.activity.isExpanded {
                        ActivitySection(store: store)
                    }
                }
            }
        }
        .onAppear { store.activity.refresh(store.enabledServices, ifOlderThan: 60) }
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
            let cloud = store.details[service]?.cloudCredits?.expiresAt
            return snapshot.resetDates + [cloud].compactMap { $0 }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08))
    }

    static let headerSpacing: CGFloat = 9
    static let headerPadding: CGFloat = 18
    static let headerButtonSize: CGFloat = 27
    private static let appGlyphSize: CGFloat = 28
    private static let appNameSize: CGFloat = 13
    private static let appNameTracking: CGFloat = 1.2
    private static let appCaption = "AI USAGE MONITOR"

    private static let versionSize: CGFloat = 8
    private static let versionGap: CGFloat = 5
    /// "v0.6.0" next to the app name, so a screenshot tells which version it is. Empty
    /// when the bundle has no version (e.g. `swift test`).
    static let versionText: String = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty
        else { return "" }
        return "v\(version)"
    }()

    /// Width the header needs with the `primeTime` badge between the titles and the
    /// buttons, room for a spacer on either side, and with the update button when one shows.
    /// The panel widens to it when the columns alone are narrower.
    static func headerWidth(primeTime: PrimeTimeNotice?, updateButton: Bool = false) -> CGFloat {
        var name = textWidth("LIMITA", font: AppFont.ns(appNameSize), tracking: appNameTracking)
        if !versionText.isEmpty {
            name += versionGap + textWidth(versionText, font: AppFont.ns(versionSize), tracking: DashboardStyle.captionTracking)
        }
        let titles = max(
            name,
            textWidth(appCaption, font: AppFont.ns(DashboardStyle.captionSize), tracking: DashboardStyle.captionTracking)
        )
        let left = appGlyphSize + headerSpacing + titles
        let buttons: CGFloat = updateButton ? 4 : 3
        let right = buttons * headerButtonSize + (buttons - 1) * headerSpacing
        guard let primeTime else { return 2 * headerPadding + left + headerSpacing + right }
        // Each side of the badge: a spacer of zero or more between two header spacings.
        return 2 * headerPadding + left + right + PrimeTimeBadge.width(primeTime) + 4 * headerSpacing
    }

    static func textWidth(_ text: String, font: NSFont, tracking: CGFloat) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font, .kern: tracking]).size().width) + 2
    }

    /// Titles on the left and buttons on the right. The prime-time badge follows the
    /// titles when the columns sit side by side, and is centered between titles and
    /// buttons over a single column.
    private var header: some View {
        HStack(spacing: Self.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                Image("StatusIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 16, height: 16)
            }
            .frame(width: Self.appGlyphSize, height: Self.appGlyphSize)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: Self.versionGap) {
                    Text("LIMITA")
                        .font(.app(Self.appNameSize))
                        .tracking(Self.appNameTracking)
                    if !Self.versionText.isEmpty {
                        Text(Self.versionText)
                            .font(.app(Self.versionSize))
                            .tracking(DashboardStyle.captionTracking)
                            .foregroundStyle(DashboardStyle.faintCaption)
                    }
                }
                Text(Self.appCaption)
                    .caption()
            }

            if let notice = store.primeTimeNotice, store.enabledServices.count > 1 {
                PrimeTimeBadge(notice: notice)
            }

            Spacer(minLength: 0)

            if let notice = store.primeTimeNotice, store.enabledServices.count <= 1 {
                PrimeTimeBadge(notice: notice)

                Spacer(minLength: 0)
            }

            if let release = store.updater.available {
                UpdateButton(updater: store.updater, release: release)
            }

            Button {
                store.hoverEnabled.toggle()
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.08))
                    HoverPillGlyph(crossedOut: !store.hoverEnabled)
                }
                .frame(width: Self.headerButtonSize, height: Self.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help(store.hoverEnabled ? "Turn off the hover pill (⌃⌥H)" : "Turn on the hover pill (⌃⌥H)")
            .accessibilityLabel(store.hoverEnabled ? "Turn off hover pill" : "Turn on hover pill")

            Button {
                store.showsMenuBarIcon.toggle()
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.08))
                    MenuBarIconGlyph(crossedOut: !store.showsMenuBarIcon)
                }
                .frame(width: Self.headerButtonSize, height: Self.headerButtonSize)
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
                    .frame(width: Self.headerButtonSize, height: Self.headerButtonSize)
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .accessibilityLabel("Refresh")
            }
        }
        .padding(.horizontal, Self.headerPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Service column

    private func serviceDashboard(_ service: Service, state: ServiceState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            // Name on the left, how fresh the data is on the right. The meter titles
            // already say "used" or "left".
            HStack(spacing: 8) {
                ServiceBadge(service: service)

                HStack(spacing: 6) {
                    Text([service.displayName, store.details[service]?.plan].compactMap { $0 }.joined(separator: " "))
                        .font(.app(14))
                    LevelDot(state: state, now: now)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(statusLabel(state))
                        .caption()
                    if let snapshot = state.snapshot {
                        Text("UPDATED \(Self.updatedText(snapshot.capturedAt, now: now).uppercased())")
                            .caption(faint: true)
                    }
                }
                .lineLimit(1)
            }
            // Same height in every column, so the meters line up.
            .frame(height: 36)

            if let message = store.setupMessage, message.service == service {
                SetupMessage(text: message.text) { store.setupMessage = nil }
            } else if let snapshot = state.snapshot {
                meterRows(service: service, snapshot: snapshot, stale: state.isStale, now: now)

                detailTiles(for: service)

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

    /// Empty space between the meters' rows.
    static let rowSpacing: CGFloat = 16

    /// One row per meter: the plan's windows, the per-model ones, then the credits. The
    /// per-model ones and the credits can be folded into capsules in the activity
    /// toggle's line.
    private func meterRows(service: Service, snapshot: LimitSnapshot, stale: Bool, now: Date) -> some View {
        let soft = DashboardStyle.accent(for: service).opacity(0.72)
        let rows: [(fold: String?, meter: MeterView)] = [
            (nil, fiveHourMetric(service: service, snapshot: snapshot, stale: stale, now: now)),
            (nil, sevenDayMetric(service: service, snapshot: snapshot, stale: stale, now: now)),
        ]
            + snapshot.scoped.map {
                ($0.name.uppercased(), metric($0.title, service: service, window: $0.window, color: soft, stale: stale, now: now))
            }
            + Self.creditMeters(for: service, details: store.details[service] ?? AccountDetails(), now: now).map {
                ($0.title, creditMeter($0, service: service, stale: stale))
            }
        let shown = rows.filter { row in row.fold.map { !store.isCollapsed($0, of: service) } ?? true }
        return VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(shown.indices, id: \.self) { index in
                let row = shown[index]
                if let fold = row.fold {
                    row.meter.collapsible { store.setCollapsed(true, fold, of: service) }
                } else {
                    row.meter
                }
            }
        }
    }

    /// The folded meters' capsules, one per name: Fable's 5-hour and weekly windows fold
    /// together. Only meters the service reported count.
    static func foldedMeters(service: Service, store: LimitsStore) -> [String] {
        guard let snapshot = store.state(for: service).snapshot else { return [] }
        let names = snapshot.scoped.map { $0.name.uppercased() }
            + creditMeters(for: service, details: store.details[service] ?? AccountDetails(), now: Date()).map(\.title)
        var folded: [String] = []
        for name in names where store.isCollapsed(name, of: service) && !folded.contains(name) {
            folded.append(name)
        }
        return folded
    }

    private func fiveHourMetric(service: Service, snapshot: LimitSnapshot, stale: Bool, now: Date) -> MeterView {
        if snapshot.hasNoFiveHourLimit {
            // Stands in for the 5-hour meter when the plan has no 5-hour limit.
            return MeterView(title: "5 HOURS", value: "∞", amount: nil, fill: 0, color: .clear,
                             caption: "NO 5-HOUR LIMIT", stale: false)
        }
        return metric("5 HOURS", service: service, window: snapshot.fiveHour,
                      color: DashboardStyle.fiveHourBar(for: service), stale: stale, now: now)
    }

    private func sevenDayMetric(service: Service, snapshot: LimitSnapshot, stale: Bool, now: Date) -> MeterView {
        metric("7 DAYS", service: service, window: snapshot.sevenDay,
               color: DashboardStyle.accent(for: service).opacity(0.72), stale: stale, now: now)
    }

    /// One window's meter. The number and bar show what `service` is displayed as (left
    /// or used). The number stays white; the bar's colour follows usage, so red still
    /// means "almost out". Stale numbers are dimmed so they don't read as current.
    private func metric(
        _ title: String, service: Service, window: LimitWindow?, color: Color, stale: Bool, now: Date
    ) -> MeterView {
        MeterView(
            title: "\(title) \(service.percentMeaning.uppercased())",
            value: window?.shownText(for: service, at: now) ?? "—",
            amount: nil,
            fill: (window?.shownPercent(for: service, at: now) ?? 0) / 100,
            color: DashboardStyle.pressureColor(window?.displayFraction(at: now) ?? 0, fallback: color),
            caption: window?.resetText(at: now)?.uppercased() ?? "NO WINDOW",
            stale: stale
        )
    }

    // MARK: - Balances

    private func creditMeter(_ meter: CreditMeter, service: Service, stale: Bool) -> MeterView {
        MeterView(
            title: meter.title,
            value: meter.value,
            amount: meter.amount,
            fill: meter.fill,
            color: DashboardStyle.pressureColor(meter.used, fallback: DashboardStyle.accent(for: service).opacity(0.72)),
            caption: meter.caption,
            stale: stale
        )
    }

    /// What a credit meter shows, worked out apart from the view so it can be tested.
    struct CreditMeter: Equatable {
        let title: String
        let value: String
        /// Dollars to the right of the bar, e.g. "$163 OF $250 LEFT".
        let amount: String?
        /// 0...1 of the bar that is filled.
        let fill: Double
        /// 0...1 spent, which picks the bar's colour.
        let used: Double
        let caption: String
    }

    /// Like Claude's own settings: the percentage and the bar show what is spent, the
    /// dollars what is left. A meter is hidden when the service did not report its value,
    /// and usage credits also while they are turned off.
    static func creditMeters(for service: Service, details: AccountDetails, now: Date) -> [CreditMeter] {
        guard service == .claude else { return [] }
        var meters: [CreditMeter] = []
        switch details.claudeUsageCredits {
        case .off, nil:
            break
        case .balance(let dollars):
            meters.append(CreditMeter(title: "USAGE CREDITS", value: usd(dollars), amount: "LEFT", fill: 0, used: 0, caption: "BALANCE"))
        case .spent(let dollars, let limit?) where limit > 0:
            let used = min(max(dollars / limit, 0), 1)
            meters.append(CreditMeter(
                title: "USAGE CREDITS", value: percent(used), amount: "\(dollarsText(max(limit - dollars, 0))) OF \(dollarsText(limit)) LEFT",
                fill: used, used: used, caption: "SPEND LIMIT"
            ))
        case .spent(let dollars, _):
            meters.append(CreditMeter(title: "USAGE CREDITS", value: usd(dollars), amount: "SPENT", fill: 0, used: 0, caption: "NO SPEND LIMIT"))
        }
        if let cloud = details.cloudCredits {
            let caption = cloudResetText(cloud.expiresAt, now: now)
            if let limit = cloud.limit, limit > 0 {
                let used = 1 - min(max(cloud.remaining / limit, 0), 1)
                meters.append(CreditMeter(
                    title: "CLOUD CREDITS", value: percent(used), amount: "\(dollarsText(cloud.remaining)) OF \(dollarsText(limit)) LEFT",
                    fill: used, used: used, caption: caption
                ))
            } else {
                meters.append(CreditMeter(title: "CLOUD CREDITS", value: usd(cloud.remaining), amount: "LEFT", fill: 0, used: 0, caption: caption))
            }
        }
        return meters
    }

    /// Whole dollars, as Claude's settings show them, but cents below $10 so a small
    /// balance does not round to nothing.
    static func dollarsText(_ value: Double) -> String {
        value >= 10
            ? value.formatted(.currency(code: "USD").precision(.fractionLength(0)).locale(.english))
            : usd(value)
    }

    /// A countdown within a week, like the limits'; further out the date, which stays
    /// within the meter's width.
    static func cloudResetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "NO RESET DATE" }
        if date.timeIntervalSince(now) <= 7 * 86400 {
            return LimitWindow(usedPercent: 0, resetsAt: date).resetText(at: now)?.uppercased() ?? ""
        }
        let formatter = DateFormatter()
        formatter.locale = .english
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "RESETS ON \(formatter.string(from: date).uppercased())"
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    /// Tiles under the meters, two to a row on the meters' grid. A tile is hidden when
    /// the service did not report its value.
    @ViewBuilder
    private func detailTiles(for service: Service) -> some View {
        let rows = Self.detailRows(for: service, details: store.details[service] ?? AccountDetails())
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { start in
                    HStack(alignment: .top, spacing: Self.meterSpacing) {
                        detailTile(rows[start])
                        if start + 1 < rows.count {
                            detailTile(rows[start + 1])
                        } else {
                            Color.clear.frame(height: 0)
                                .frame(minWidth: Self.meterWidth, maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func detailTile(_ row: DetailRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.label)
                .caption()
            Text(row.value)
                .font(.app(DashboardStyle.tileValueSize))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: Self.meterWidth, maxWidth: .infinity, alignment: .leading)
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
            // Claude's credits are meters; see `creditMeters`.
            break
        }
        return rows
    }

    private static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(.english))
    }
}

// MARK: - Pieces

/// A meter: the title on top, and under it the big value with the bar and the caption
/// after it, the value as tall as the two. Credits put their dollars right of the bar.
/// Stale numbers are dimmed so they don't read as current.
struct MeterView: View {
    let title: String
    let value: String
    let amount: String?
    /// 0...1 of the bar that is filled.
    let fill: Double
    let color: Color
    let caption: String
    let stale: Bool
    /// Shows a chevron after the title that folds the meter away.
    var onCollapse: (() -> Void)?

    func collapsible(_ action: @escaping () -> Void) -> MeterView {
        var meter = self
        meter.onCollapse = action
        return meter
    }

    /// Room for "100%", so the bars of all rows start at the same place.
    static let valueWidth: CGFloat = ExpandedView.textWidth(
        "100%", font: AppFont.ns(DashboardStyle.meterValueSize), tracking: 0
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .caption(size: DashboardStyle.meterCaptionSize)
                    .lineLimit(1)
                if let onCollapse {
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(DashboardStyle.caption)
                            .frame(width: 14, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide \(title.lowercased())")
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Text(value)
                    .font(.app(DashboardStyle.meterValueSize))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: Self.valueWidth, alignment: .leading)
                    .opacity(stale ? 0.55 : 1)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        bar
                        if let amount {
                            Text(amount)
                                .caption(size: DashboardStyle.meterCaptionSize)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                                .opacity(stale ? 0.55 : 1)
                        }
                    }
                    Text(caption)
                        .caption(size: DashboardStyle.meterCaptionSize)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(fill, 0), 1))
                    .opacity(stale ? 0.55 : 1)
            }
        }
        .frame(height: 4)
    }
}

/// Folded meters, one capsule each like the activity toggle, left to right and onto the
/// next line when they run out of room. A tap unfolds the meter.
struct FoldedMeters: View {
    let names: [String]
    let unfold: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Button { unfold(name) } label: {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.app(DashboardStyle.captionSize))
                            .tracking(DashboardStyle.captionTracking)
                            .lineLimit(1)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(DashboardStyle.caption)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(name.lowercased())")
            }
        }
    }
}

/// Lays its views out in rows, left to right, wrapping at the proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

/// The app glyph on the menu-bar toggle shows the current state: plain while the icon is
/// shown, crossed out while it is hidden.
struct MenuBarIconGlyph: View {
    let crossedOut: Bool

    var body: some View {
        ZStack {
            Image("StatusIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 13, height: 13)
            if crossedOut { GlyphSlash() }
        }
    }
}

/// The hover-pill toggle: a cursor, plain while the pill is on, crossed out while it is off.
struct HoverPillGlyph: View {
    let crossedOut: Bool

    var body: some View {
        ZStack {
            Image(systemName: "cursorarrow")
                .font(.system(size: 11, weight: .bold))
            if crossedOut { GlyphSlash() }
        }
    }
}

/// A slash over a header-button glyph. The dark rim cuts the glyph so the slash reads
/// at this size.
struct GlyphSlash: View {
    var body: some View {
        ZStack {
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
            Image(service.logoName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
    }
}

/// Says that a service is in its peak hours, when work burns through its limits faster.
/// Sits in the header between the titles and the buttons.
struct PrimeTimeBadge: View {
    let notice: PrimeTimeNotice

    private static let iconSize: CGFloat = 26
    private static let spacing: CGFloat = 9
    private static let horizontalPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 7
    /// The app font has no bold face, so bold is the text drawn again this far to the right.
    private static let boldOffset: CGFloat = 0.5

    /// Room the badge takes, known before SwiftUI lays it out so the panel can be sized.
    /// A little slack covers SwiftUI's tracking, which measures wider than AppKit's.
    static func width(_ notice: PrimeTimeNotice) -> CGFloat {
        let font = AppFont.ns(DashboardStyle.captionSize)
        let text = max(
            ExpandedView.textWidth(notice.firstLine, font: font, tracking: DashboardStyle.captionTracking) + boldOffset,
            ExpandedView.textWidth(notice.detail, font: font, tracking: DashboardStyle.captionTracking)
        )
        return 2 * horizontalPadding + iconSize + spacing + text + 6
    }

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            BurningGauge()
                .frame(width: Self.iconSize, height: Self.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                firstLine
                Text(notice.detail)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .font(.app(DashboardStyle.captionSize))
            .tracking(DashboardStyle.captionTracking)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        // Never wraps or truncates; `width` only reserves the room.
        .fixedSize()
        .background(Capsule().fill(DashboardStyle.primeTime.opacity(0.10)))
        .overlay(Capsule().stroke(DashboardStyle.primeTime.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(notice.firstLine) \(notice.detail)")
    }

    /// The service name, when there is one, in bright bold: a second copy of the line,
    /// shifted right, with everything but the name transparent.
    @ViewBuilder
    private var firstLine: some View {
        let rest = Text(notice.title).foregroundColor(.white.opacity(0.85))
        if let strong = notice.strong {
            ZStack(alignment: .leading) {
                Text(strong).foregroundColor(.white) + rest
                (Text(strong).foregroundColor(.white) + Text(notice.title).foregroundColor(.clear))
                    .offset(x: Self.boldOffset)
            }
        } else {
            rest
        }
    }
}

/// The burning speedometer, looping through the frames of `PrimeTimeSprite`.
private struct BurningGauge: View {
    var body: some View {
        let frames = PrimeTimeSprite.frames
        TimelineView(.animation(minimumInterval: 1 / PrimeTimeSprite.fps)) { context in
            if frames.isEmpty {
                Color.clear
            } else {
                let index = Int(context.date.timeIntervalSinceReferenceDate * PrimeTimeSprite.fps) % frames.count
                Image(nsImage: frames[index])
                    .resizable()
                    .interpolation(.high)
            }
        }
    }
}

/// The badge animation: every frame in one sprite sheet, `prime-time.webp`, shared with
/// the Windows app. Built by `scripts/prime-time-sprite.sh` at the repo root; the numbers here must match it.
enum PrimeTimeSprite {
    static let fps: Double = 24
    static let columns = 14
    static let frameCount = 196
    static let framePixels = 78

    /// Cut once, on first use. Empty when the sheet is missing (e.g. `swift test`).
    @MainActor static let frames: [NSImage] = {
        guard let url = Bundle.main.url(forResource: "prime-time", withExtension: "webp"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }
        return cut(sheet)
    }()

    static func cut(_ sheet: CGImage) -> [NSImage] {
        (0..<frameCount).compactMap { index in
            let rect = CGRect(
                x: (index % columns) * framePixels,
                y: (index / columns) * framePixels,
                width: framePixels,
                height: framePixels
            )
            return sheet.cropping(to: rect).map { NSImage(cgImage: $0, size: .zero) }
        }
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

// MARK: - Update

/// Shown in the header only while a newer Limita is out: an arrow down to a line,
/// in the healthy green, tinted like the prime-time badge. Installing swaps the app
/// and reopens it; a spinner stands in meanwhile.
private struct UpdateButton: View {
    let updater: AppUpdater
    let release: AppUpdater.Release

    var body: some View {
        Button {
            updater.install()
        } label: {
            ZStack {
                Circle().fill(DashboardStyle.healthy.opacity(0.14))
                Circle().strokeBorder(DashboardStyle.healthy.opacity(0.35), lineWidth: 1)
                if updater.phase == .installing {
                    ProgressView().controlSize(.mini).tint(DashboardStyle.healthy)
                } else {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DashboardStyle.healthy)
                }
            }
            .frame(width: ExpandedView.headerButtonSize, height: ExpandedView.headerButtonSize)
        }
        .buttonStyle(.plain)
        .disabled(updater.phase == .installing)
        .help(help)
        .accessibilityLabel("Install Limita \(release.version)")
    }

    private var help: String {
        switch updater.phase {
        case .installing: "Installing Limita \(release.version)…"
        case .failed(let reason): "Update failed: \(reason). Click to try again."
        case .idle: "Install Limita \(release.version)"
        }
    }
}

// MARK: - Style

enum DashboardStyle {
    static let healthy = Color(red: 0.32, green: 0.92, blue: 0.58)
    /// The prime-time badge's outline, matching the flames of its animation.
    static let primeTime = Color(red: 1, green: 0.45, blue: 0.18)
    static let cornerRadius: CGFloat = 16

    /// Small uppercase labels. Sized and tinted for ~4.5:1 contrast on black.
    static let captionSize: CGFloat = 9.5
    static let caption = Color.white.opacity(0.62)
    /// The least important line, e.g. "UPDATED …".
    static let faintCaption = Color.white.opacity(0.48)
    static let captionTracking: CGFloat = 0.3
    /// The meters' titles and countdowns, a little larger than other captions.
    static let meterCaptionSize: CGFloat = 10.5
    /// The meters' percentages, as tall as the bar and countdown beside them.
    static let meterValueSize: CGFloat = 26
    /// Values next to captions, e.g. messages.
    static let valueSize: CGFloat = 11
    /// Values in the tiles under the meters, e.g. balances.
    static let tileValueSize: CGFloat = 13

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
    func caption(faint: Bool = false, size: CGFloat = DashboardStyle.captionSize) -> some View {
        font(.app(size))
            .tracking(DashboardStyle.captionTracking)
            .foregroundStyle(faint ? DashboardStyle.faintCaption : DashboardStyle.caption)
    }
}
