import SwiftUI

/// The panel that drops down under the service columns: a year of tokens per day for
/// each service, laid out like GitHub's contribution graph, under that service's column.
struct ActivitySection: View {
    let store: LimitsStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.enabledServices.enumerated()), id: \.element) { index, service in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.08))
                        .frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 14)
                }
                ActivityGraph(
                    service: service,
                    days: store.activity.days[service],
                    loaded: store.activity.isLoaded
                )
                .padding(.horizontal, ExpandedView.columnPadding)
                .padding(.top, 13)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The round button with a chevron under the dashboard that opens and closes the panel.
struct ActivityToggle: View {
    let store: LimitsStore

    var body: some View {
        let expanded = store.activity.isExpanded
        Button {
            store.activity.isExpanded.toggle()
            store.activity.refresh(store.enabledServices, ifOlderThan: 60)
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .offset(y: expanded ? -0.5 : 0.5)
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide activity" : "Show activity")
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

/// One service's year: weeks left to right, scrolled to the newest. Hovering a day
/// shows its tokens in the caption; tooltips never appear in this panel.
struct ActivityGraph: View {
    let service: Service
    let days: [DayKey: Int]?
    let loaded: Bool

    static let cell: CGFloat = 10
    static let gap: CGFloat = 3
    private static let step = cell + gap
    private static let monthRowHeight: CGFloat = 13
    private static let weekdayColumnWidth: CGFloat = 24

    @State private var hovered: ActivityGrid.Day?

    var body: some View {
        let grid = ActivityGrid(days: days ?? [:])
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ACTIVITY")
                    .caption()
                Spacer(minLength: 0)
                Text(caption(grid))
                    .caption(faint: hovered == nil)
                    .lineLimit(1)
                    .monospacedDigit()
            }

            HStack(alignment: .top, spacing: 0) {
                weekdayLabels
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        monthLabels(grid)
                        cells(grid)
                    }
                }
                .defaultScrollAnchor(.trailing)
            }

            legend
        }
        // Drawn over the whole graph, so the scroll view does not clip it.
        .overlayPreferenceValue(HoveredCellKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor, let hovered {
                    TokenChip(tokens: hovered.tokens, service: service, cell: proxy[anchor], bounds: proxy.size)
                }
            }
        }
    }

    private func caption(_ grid: ActivityGrid) -> String {
        if let hovered {
            return hovered.date.formatted(.dateTime.locale(.english).weekday(.abbreviated).month(.abbreviated).day().year()).uppercased()
        }
        guard loaded else { return "READING LOGS…" }
        return "\(TokenFormat.compact(grid.total)) TOKENS / YEAR"
    }

    private var weekdayLabels: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(["", "Mon", "", "Wed", "", "Fri", ""][row])
                    .caption(size: 8.5)
                    .frame(height: Self.cell)
            }
        }
        .padding(.top, Self.monthRowHeight)
        .frame(width: Self.weekdayColumnWidth, alignment: .leading)
    }

    private func monthLabels(_ grid: ActivityGrid) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(grid.months, id: \.column) { label in
                Text(label.text)
                    .caption(size: 8.5)
                    .fixedSize()
                    .offset(x: CGFloat(label.column) * Self.step)
            }
        }
        .frame(width: CGFloat(ActivityGrid.weeks) * Self.step - Self.gap, height: Self.monthRowHeight, alignment: .topLeading)
    }

    private func cells(_ grid: ActivityGrid) -> some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(grid.columns.indices, id: \.self) { week in
                VStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        if let day = grid.columns[week][weekday] {
                            ActivityCell(level: day.level, service: service, highlighted: day.key == hovered?.key)
                                .anchorPreference(key: HoveredCellKey.self, value: .bounds) {
                                    day.key == hovered?.key ? $0 : nil
                                }
                        } else {
                            Color.clear.frame(width: Self.cell, height: Self.cell)
                        }
                    }
                }
            }
        }
        // One hover handler for the whole grid instead of one per cell. A click shows
        // the day too, in case the panel gets no hover events.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover(day(at: point, in: grid))
            case .ended: hover(nil)
            }
        }
        .onTapGesture { point in hover(day(at: point, in: grid)) }
    }

    /// Only a different day re-renders, not every pixel the cursor moves.
    private func hover(_ day: ActivityGrid.Day?) {
        if day?.key != hovered?.key { hovered = day }
    }

    private func day(at point: CGPoint, in grid: ActivityGrid) -> ActivityGrid.Day? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let week = Int(point.x / Self.step)
        let weekday = Int(point.y / Self.step)
        guard grid.columns.indices.contains(week), weekday < 7 else { return nil }
        return grid.columns[week][weekday]
    }

    private var legend: some View {
        HStack(spacing: Self.gap) {
            Spacer(minLength: 0)
            Text("LESS").caption(size: 8.5).padding(.trailing, 3)
            ForEach(0..<5, id: \.self) { level in
                ActivityCell(level: level, service: service, highlighted: false)
            }
            Text("MORE").caption(size: 8.5).padding(.leading, 3)
        }
    }
}

/// Where the hovered cell is, for the chip above it.
private struct HoveredCellKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The hovered day's tokens in thousands, in a small chip just above its cell and
/// kept inside the graph.
struct TokenChip: View {
    let tokens: Int
    let service: Service
    let cell: CGRect
    let bounds: CGSize

    private static let height: CGFloat = 16

    var body: some View {
        let text = TokenFormat.thousands(tokens)
        // The font is monospaced, so the width is known before layout.
        let width = CGFloat(text.count) * 5.6 + 12
        let x = min(max(cell.midX, width / 2), bounds.width - width / 2)
        Text(text)
            .font(.app(9))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, height: Self.height)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(white: 0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(DashboardStyle.accent(for: service).opacity(0.6), lineWidth: 1)
                    )
            )
            .position(x: x, y: cell.minY - Self.height / 2 - 3)
            .allowsHitTesting(false)
    }
}

struct ActivityCell: View {
    let level: Int
    let service: Service
    let highlighted: Bool

    /// Opacity of the service's colour for shades 1...4.
    static let shades: [Double] = [0.28, 0.5, 0.74, 1]

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(level == 0 ? Color.white.opacity(0.07) : DashboardStyle.accent(for: service).opacity(Self.shades[level - 1]))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(Color.white.opacity(0.85), lineWidth: 1)
                }
            }
            .frame(width: ActivityGraph.cell, height: ActivityGraph.cell)
    }
}
