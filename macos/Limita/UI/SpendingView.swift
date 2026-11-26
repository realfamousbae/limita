import SwiftUI

enum SpendingMode: String, CaseIterable {
    case models, money
    var title: String { rawValue.uppercased() }
}

struct SpendingColumn: View {
    let service: Service
    let history: SpendHistory?
    let mode: SpendingMode
    let period: ActivityPeriod
    @State private var selected: DayKey?
    @State private var visibleWeeks: Int?

    private static let colors: [Color] = [.init(red: 0.39, green: 0.68, blue: 0.96), .orange, .mint, .purple, .pink, .yellow, .cyan]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let history, !history.days.isEmpty {
                let totals = history.dailyTotals
                let grid = ActivityGrid(days: [:], period: period, visibleWeeks: visibleWeeks, spending: totals)
                SummaryTiles(items: history.periodTiles(for: grid))
                if period == .week {
                    week(grid.cells[0].compactMap { $0 }, history: history)
                    Text(selected.map { description($0, amounts: history.days[$0], currency: history.currency) } ?? " ")
                        .caption()
                        .lineLimit(2, reservesSpace: true)
                } else {
                    ActivityCalendar(grid: grid, service: service, chipText: { day in
                        totals[day.key].map { SpendHistory.amount($0, currency: history.currency) } ?? "No data"
                    }, dayDetails: mode == .models ? { day in
                        breakdown(history.days[day.key], currency: history.currency)
                    } : nil) { width in
                        visibleWeeks = ActivityGrid.weeksFitting(width: width)
                    }
                }
                if history.estimated { Text("Estimated from balance changes").caption() }
            } else {
                Text("No spending history yet")
                    .caption()
            }
        }
        .onChange(of: period) { _, _ in selected = nil }
        .onChange(of: mode) { _, _ in selected = nil }
    }

    private func week(_ days: [ActivityGrid.Day], history: SpendHistory) -> some View {
        let peak = max(days.map {
            let amounts = history.days[$0.key]
            return mode == .models ? (amounts ?? [:]).values.filter { $0 > 0 }.reduce(0, +) : sum(amounts)
        }.max() ?? 0, 0.000_001)
        let models = history.days.keys.sorted().flatMap { day in
            (history.days[day] ?? [:]).keys.filter { !$0.isEmpty }.sorted()
        }
        var seen: Set<String> = []
        let names = models.filter { seen.insert($0).inserted }
        let colors = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            (name, Self.colors[index % Self.colors.count])
        })
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.element.key) { index, day in
                let amounts = history.days[day.key]
                let items = mode == .models ? (amounts ?? [:]).filter { !$0.key.isEmpty }.sorted { $0.key < $1.key } : []
                VStack(spacing: 7) {
                    dayButton(day.key, amounts: amounts, currency: history.currency) {
                        ZStack(alignment: .bottom) {
                            VStack(spacing: 0) {
                                ForEach(0..<4) { i in
                                    Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                                    if i < 3 { Spacer(minLength: 0) }
                                }
                            }
                            if let amounts {
                                if items.isEmpty {
                                    Rectangle().fill(Self.colors[0]).frame(height: max(1, 96 * sum(amounts) / peak))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                } else {
                                    VStack(spacing: 0) {
                                        ForEach(items, id: \.key) { model, value in
                                            Rectangle().fill(colors[model] ?? Self.colors[0]).frame(height: max(0, 96 * value / peak))
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                        .frame(height: 96)
                        .padding(.horizontal, 5)
                    }
                    Text(index.isMultiple(of: 3) ? day.date.formatted(.dateTime.day().month(.abbreviated)) : " ")
                        .font(.app(9))
                        .lineLimit(1)
                        .foregroundStyle(DashboardStyle.caption)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayButton<Content: View>(_ date: DayKey, amounts: [String: Double]?, currency: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        Button { selected = date } label: { content().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .onHover { hovering in if hovering { selected = date } else if selected == date { selected = nil } }
            .accessibilityLabel(description(date, amounts: amounts, currency: currency))
            .help(description(date, amounts: amounts, currency: currency))
    }

    private func description(_ date: DayKey, amounts: [String: Double]?, currency: String) -> String {
        guard let amounts else { return "\(date) · No data" }
        let total = SpendHistory.amount(amounts.values.reduce(0, +), currency: currency)
        let details = mode == .models ? breakdown(amounts, currency: currency) : nil
        return [date, total, details].compactMap { $0 }.joined(separator: " · ")
    }

    private func breakdown(_ amounts: [String: Double]?, currency: String) -> String? {
        let details = (amounts ?? [:]).filter { !$0.key.isEmpty }.sorted { $0.value > $1.value }.map {
            "\($0.key) \(SpendHistory.amount($0.value, currency: currency))"
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func sum(_ amounts: [String: Double]?) -> Double { max(0, (amounts ?? [:]).values.reduce(0, +)) }

}
