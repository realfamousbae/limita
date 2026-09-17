import SwiftUI

/// Full expanded panel with progress bars for both services
struct ExpandedView: View {
    var store: LimitsStore
    @State private var loginTarget: Service? = nil
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Limita")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    Task {
                        isRefreshing = true
                        await store.refresh()
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .rotationEffect(isRefreshing ? .degrees(360) : .zero)
                        .animation(
                            isRefreshing
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Codex block
            serviceBlock(service: .codex, status: store.codex)

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Claude block
            serviceBlock(service: .claude, status: store.claude)

            // Last updated footer
            let lastDate = store.codex.lastUpdated ?? store.claude.lastUpdated
            if let date = lastDate {
                Text("Обновлено: \(date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .padding(.top, 4)
            } else {
                Spacer().frame(height: 12)
            }
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
        .sheet(item: $loginTarget) { svc in
            LoginSheet(service: svc, store: store)
        }
    }

    @ViewBuilder
    private func serviceBlock(service: Service, status: ServiceStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Service title row
            HStack(spacing: 6) {
                Text(service.icon)
                    .font(.system(size: 14))
                Text(service.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !status.isLoggedIn {
                    Button("Войти") { loginTarget = service }
                        .font(.system(size: 11))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }

            if status.isLoggedIn {
                limitRow(label: "5h", limit: status.fiveHour, color: .blue)
                limitRow(label: "7d", limit: status.weekly, color: .purple)
            } else {
                Text(status.errorMessage ?? "Нажмите «Войти» для авторизации")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func limitRow(label: String, limit: ServiceLimit, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 6)
                    Capsule()
                        .fill(barColor(fraction: limit.fraction, base: color))
                        .frame(width: max(4, geo.size.width * limit.fraction), height: 6)
                        .animation(.easeInOut(duration: 0.5), value: limit.fraction)
                }
            }
            .frame(height: 6)

            Text(limit.percentText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func barColor(fraction: Double, base: Color) -> Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return base
    }
}
