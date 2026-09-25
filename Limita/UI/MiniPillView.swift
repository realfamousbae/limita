import SwiftUI

/// Compact summary shown when the cursor rests at the top edge: each connected
/// service's 5-hour window (weekly if the plan has no 5-hour limit), as left (Codex) or
/// used (Claude). Only the dot is coloured, by that window; the text stays plain.
/// Click to expand.
struct MiniPillView: View {
    let store: LimitsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 12) {
                if store.enabledServices.isEmpty {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Connect a service")
                        .font(.app(11))
                } else {
                    ForEach(Array(store.enabledServices.enumerated()), id: \.element) { index, service in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.14))
                                .frame(width: 1, height: 14)
                        }
                        indicator(service, state: store.state(for: service), now: context.date)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
    }

    private func indicator(_ service: Service, state: ServiceState, now: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: service.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DashboardStyle.accent(for: service))
            LevelDot(state: state, now: now)
            Text(Self.label(for: service, state: state, now: now))
                .font(.app(11))
                .monospacedDigit()
        }
    }

    static func label(for service: Service, state: ServiceState, now: Date) -> String {
        guard let (label, window) = state.snapshot?.headline else { return "5h —" }
        return "\(label) \(window.shownText(for: service, at: now)) \(service.percentMeaning)"
    }
}
