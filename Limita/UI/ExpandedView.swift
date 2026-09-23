import SwiftUI

struct ExpandedView: View {
    var store: LimitsStore
    @State private var setupMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 18)

            HStack(spacing: 0) {
                serviceDashboard(.codex, state: store.codex)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 14)

                serviceDashboard(.claude, state: store.claude)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 28, y: 16)
        .alert("Подключение Claude Code", isPresented: setupAlertIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(setupMessage ?? "")
        }
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

            HStack(spacing: 5) {
                Circle().fill(Color(red: 0.32, green: 0.92, blue: 0.58)).frame(width: 5, height: 5)
                Text("LOCAL")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.6)
            }
            .foregroundStyle(.white.opacity(0.48))
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(Capsule().fill(Color.white.opacity(0.07)))

            Button {
                Task { await store.refresh() }
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.08))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(store.isRefreshing ? .degrees(360) : .zero)
                }
                .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .animation(
                store.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                value: store.isRefreshing
            )
            .help("Обновить")
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private func serviceDashboard(_ service: Service, state: ServiceState) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent(for: service).opacity(0.14))
                    Image(systemName: service == .codex ? "bolt.fill" : "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent(for: service))
                }
                .frame(width: 29, height: 29)

                VStack(alignment: .leading, spacing: 1) {
                    Text(service.displayName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    HStack(spacing: 4) {
                        Circle().fill(statusColor(state)).frame(width: 5, height: 5)
                        Text(state.isStale ? "STALE DATA" : state.snapshot == nil ? "NOT CONNECTED" : "LIVE DATA")
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }
                Spacer()
            }

            if let snapshot = state.snapshot {
                HStack(spacing: 10) {
                    metric("5 HOURS", window: snapshot.fiveHour, color: accent(for: service))
                    metric("7 DAYS", window: snapshot.sevenDay, color: accent(for: service).opacity(0.72))
                }

                Text("UPDATED \(snapshot.capturedAt.formatted(.relative(presentation: .numeric)).uppercased())")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(0.45)
                    .foregroundStyle(.white.opacity(0.25))
            } else {
                unavailable(service, state: state)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metric(_ title: String, window: LimitWindow?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 7, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.35))

            Text(window?.percentText ?? "—")
                .font(.system(size: 23, weight: .black, design: .rounded))
                .monospacedDigit()

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * (window?.displayFraction ?? 0))
                }
            }
            .frame(height: 4)

            Text(window?.resetText?.uppercased() ?? "NO WINDOW")
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func unavailable(_ service: Service, state: ServiceState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(state.unavailableReason ?? "Нет данных")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(2)
                .foregroundStyle(.white.opacity(0.42))

            if service == .claude {
                Button {
                    setupMessage = store.configureClaudeStatusLine()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text("CONNECT")
                    }
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 27)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var setupAlertIsPresented: Binding<Bool> {
        Binding(
            get: { setupMessage != nil },
            set: { if !$0 { setupMessage = nil } }
        )
    }
}

private func accent(for service: Service) -> Color {
    service == .codex
        ? Color(red: 0.31, green: 0.67, blue: 1)
        : Color(red: 1, green: 0.58, blue: 0.30)
}

private func statusColor(_ state: ServiceState) -> Color {
    guard let snapshot = state.snapshot else { return .white.opacity(0.32) }
    if state.isStale { return .yellow }
    if snapshot.peakFraction >= 0.9 { return .red }
    if snapshot.peakFraction >= 0.7 { return .orange }
    return Color(red: 0.32, green: 0.92, blue: 0.58)
}
