import SwiftUI

/// Compact "pill" view shown on hover — just service icons + color status dots
struct MiniPillView: View {
    var store: LimitsStore

    private func dotColor(for status: ServiceStatus) -> Color {
        let f = max(status.fiveHour.fraction, status.weekly.fraction)
        if !status.isLoggedIn { return .gray }
        if f >= 0.9 { return .red }
        if f >= 0.7 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 14) {
            serviceIndicator(icon: "⚡", status: store.codex)
            Divider()
                .frame(height: 16)
                .opacity(0.4)
            serviceIndicator(icon: "🤖", status: store.claude)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    @ViewBuilder
    private func serviceIndicator(icon: String, status: ServiceStatus) -> some View {
        HStack(spacing: 5) {
            Text(icon)
                .font(.system(size: 14))
            Circle()
                .fill(dotColor(for: status))
                .frame(width: 7, height: 7)
                .shadow(color: dotColor(for: status).opacity(0.6), radius: 3)
        }
    }
}
