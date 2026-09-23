import SwiftUI

struct ExpandedView: View {
    let store: LimitsStore

    var body: some View {
        // Relative times ("resets in 2 hours") and expired windows must advance between
        // data refreshes.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                header

                divider.frame(height: 1).padding(.horizontal, 18)

                HStack(spacing: 0) {
                    serviceDashboard(.codex, state: store.codex, now: context.date)
                    divider.frame(width: 1).padding(.vertical, 14)
                    serviceDashboard(.claude, state: store.claude, now: context.date)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08))
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text("LIMITA")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(1.2)
                Text("AI USAGE MONITOR")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.38))
            }

            Spacer()

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
            .help("Refresh")
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private func serviceDashboard(_ service: Service, state: ServiceState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DashboardStyle.accent(for: service).opacity(0.14))
                    Image(systemName: service.symbolName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DashboardStyle.accent(for: service))
                }
                .frame(width: 29, height: 29)

                VStack(alignment: .leading, spacing: 1) {
                    Text(service.displayName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    HStack(spacing: 4) {
                        Circle().fill(DashboardStyle.statusColor(state, now: now)).frame(width: 5, height: 5)
                        Text(statusLabel(state))
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }
                Spacer()
            }

            if service == .claude, let message = store.claudeSetupMessage {
                setupMessage(message)
            } else if let snapshot = state.snapshot {
                HStack(spacing: 10) {
                    metric("5 HOURS", window: snapshot.fiveHour, color: DashboardStyle.accent(for: service), now: now)
                    metric("7 DAYS", window: snapshot.sevenDay, color: DashboardStyle.accent(for: service).opacity(0.72), now: now)
                }

                detailRows(for: service)

                HStack(spacing: 6) {
                    Text("UPDATED \(snapshot.capturedAt.formatted(.relative(presentation: .numeric).locale(.english)).uppercased())")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(0.45)
                        .foregroundStyle(.white.opacity(0.25))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if state.isStale, let error = store.liveErrors[service] {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .help(error)
                    } else if service == .claude, needsConnect {
                        connectButton(compact: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text(store.liveErrors[service] ?? state.unavailableReason ?? "No data")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white.opacity(0.42))

                    if service == .claude, needsConnect {
                        connectButton(compact: false)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Balances

    /// Rows under the meters. A row is hidden when the service did not report its value.
    @ViewBuilder
    private func detailRows(for service: Service) -> some View {
        let rows = Self.detailRows(for: service, details: store.details[service] ?? AccountDetails())
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows, id: \.label) { row in
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.35))
                        Spacer(minLength: 4)
                        Text(row.value)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .help(row.help ?? "")
                }
            }
        }
    }

    struct DetailRow: Equatable {
        let label: String
        let value: String
        var help: String?
    }

    static func detailRows(for service: Service, details: AccountDetails) -> [DetailRow] {
        var rows: [DetailRow] = []
        if let resets = details.limitResets {
            rows.append(DetailRow(label: "LIMIT RESETS", value: "\(resets)", help: "Rate-limit resets available to redeem"))
        }
        switch service {
        case .codex:
            if details.codexCreditsUnlimited {
                rows.append(DetailRow(label: "CREDITS", value: "Unlimited"))
            } else if let credits = details.codexCredits {
                let dollars = credits / AccountDetails.codexCreditsPerDollar
                rows.append(DetailRow(
                    label: "CREDITS",
                    value: "\(credits.formatted(.number.precision(.fractionLength(0...2)).locale(.english))) credits · \(usd(dollars))",
                    help: "Codex credits, $1 = \(Int(AccountDetails.codexCreditsPerDollar)) credits"
                ))
            }
        case .claude:
            switch details.claudeUsageCredits {
            case .off:
                rows.append(DetailRow(label: "USAGE CREDITS", value: "Off", help: "Credits that cover usage past the plan limits"))
            case .balance(let dollars):
                rows.append(DetailRow(label: "USAGE CREDITS", value: usd(dollars), help: "Credits that cover usage past the plan limits"))
            case .spent(let dollars, let limit):
                rows.append(DetailRow(
                    label: "USAGE CREDITS",
                    value: limit.map { "\(usd(dollars)) of \(usd($0)) used" } ?? "\(usd(dollars)) used",
                    help: "Credits that cover usage past the plan limits"
                ))
            case nil:
                break
            }
            if let cloud = details.cloudCredits {
                var value = usd(cloud.remaining)
                if let limit = cloud.limit { value += " / \(usd(limit))" }
                rows.append(DetailRow(
                    label: "CLOUD CREDITS",
                    value: value,
                    help: cloud.expiresAt.map {
                        "Cloud session credits left, expire \($0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(.english)))"
                    } ?? "Cloud session credits left"
                ))
            }
        }
        return rows
    }

    private static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(.english))
    }

    /// The status-line hook is only a fallback once the usage API works.
    private var needsConnect: Bool {
        !store.isClaudeConnected && !store.hasClaudeLiveData
    }

    private func statusLabel(_ state: ServiceState) -> String {
        if state.snapshot == nil { return "NO DATA" }
        return state.isStale ? "STALE DATA" : "LIVE DATA"
    }

    private func metric(_ title: String, window: LimitWindow?, color: Color, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 7, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.35))

            Text(window?.percentText(at: now) ?? "—")
                .font(.system(size: 23, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DashboardStyle.pressureColor(window?.displayFraction(at: now) ?? 0, fallback: .white))

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule()
                        .fill(DashboardStyle.pressureColor(window?.displayFraction(at: now) ?? 0, fallback: color))
                        .frame(width: geometry.size.width * (window?.displayFraction(at: now) ?? 0))
                }
            }
            .frame(height: 4)

            Text(window?.resetText(at: now)?.uppercased() ?? "NO WINDOW")
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectButton(compact: Bool) -> some View {
        Button {
            store.connectClaude()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "link")
                Text(compact ? "RECONNECT" : "CONNECT")
            }
            .font(.system(size: compact ? 7 : 8, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .padding(.horizontal, compact ? 8 : 11)
            .frame(height: compact ? 18 : 27)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help("Add Limita to the Claude Code status line")
    }

    private func setupMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(5)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { store.claudeSetupMessage = nil }
                .buttonStyle(.plain)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .padding(.horizontal, 11)
                .frame(height: 20)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
    }
}

enum DashboardStyle {
    static let healthy = Color(red: 0.32, green: 0.92, blue: 0.58)

    static func accent(for service: Service) -> Color {
        service == .codex
            ? Color(red: 0.31, green: 0.67, blue: 1)
            : Color(red: 1, green: 0.58, blue: 0.30)
    }

    /// Orange from 70 %, red from 90 %.
    static func pressureColor(_ fraction: Double, fallback: Color) -> Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return fallback
    }

    static func statusColor(_ state: ServiceState, now: Date) -> Color {
        guard let snapshot = state.snapshot else { return .white.opacity(0.32) }
        if state.isStale { return .yellow }
        return pressureColor(snapshot.peakFraction(at: now), fallback: healthy)
    }
}
