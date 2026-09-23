import SwiftUI

/// Compact summary shown when the cursor rests at the top edge: each service's 5-hour
/// window. The dot reflects both windows and freshness. Click to expand.
struct MiniPillView: View {
    let store: LimitsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 12) {
                indicator(.codex, state: store.codex, now: context.date)
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 1, height: 14)
                indicator(.claude, state: store.claude, now: context.date)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .help("Нажмите, чтобы открыть Limita")
    }

    private func indicator(_ service: Service, state: ServiceState, now: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: service.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DashboardStyle.accent(for: service))
            Circle()
                .fill(DashboardStyle.statusColor(state, now: now))
                .frame(width: 6, height: 6)
            let fiveHour = state.snapshot?.fiveHour
            Text(fiveHour.map { "5h \($0.percentText(at: now))" } ?? "5h —")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DashboardStyle.pressureColor(fiveHour?.displayFraction(at: now) ?? 0, fallback: .white))
        }
    }
}
