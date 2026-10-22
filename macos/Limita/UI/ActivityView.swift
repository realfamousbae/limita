import SwiftUI

/// The panel that drops down under the activity toggle: a period switch, and for each
/// service, under its column, a short summary and a graph of tokens per day.
struct ActivitySection: View {
    let store: LimitsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PeriodSwitch(activity: store.activity)
                .padding(.horizontal, ExpandedView.columnPadding)
                .padding(.top, 6)
            columns
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.enabledServices.enumerated()), id: \.element) { index, service in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.08))
                        .frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 12)
                }
                ActivityColumn(service: service, grid: store.activity.grids[service], loaded: store.activity.isLoaded)
                    .padding(.horizontal, ExpandedView.columnPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// WEEK · MONTH · ALL, shared by every service's graph.
private struct PeriodSwitch: View {
    let activity: ActivityStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ActivityPeriod.allCases, id: \.self) { period in
                let selected = activity.period == period
                Button {
                    activity.period = period
                } label: {
                    Text(period.title)
                        .font(.app(DashboardStyle.captionSize))
                        .tracking(DashboardStyle.captionTracking)
                        .foregroundStyle(selected ? Color.white : DashboardStyle.caption)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// A small capsule at the bottom right of the dashboard, in line with the columns'
/// right edge, that opens and closes the panel below it. The folded meters' capsules
/// share its line, each under its own column.
struct ActivityToggle: View {
    let store: LimitsStore

    var body: some View {
        let expanded = store.activity.isExpanded
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(store.enabledServices, id: \.self) { service in
                let folded = ExpandedView.foldedMeters(service: service, store: store)
                HStack(alignment: .bottom, spacing: 6) {
                    if !folded.isEmpty {
                        FoldedMeters(names: folded) { store.setCollapsed(false, $0, of: service) }
                    }
                    Spacer(minLength: 0)
                    if service == store.enabledServices.last {
                        button(expanded: expanded)
                    }
                }
                .padding(.horizontal, ExpandedView.columnPadding)
                .frame(maxWidth: .infinity)
            }
        }
        // The columns' divider is 1 pt wide; keep the cells under their columns.
        .padding(.horizontal, store.enabledServices.count > 1 ? 0.5 : 0)
        .padding(.top, 2)
        .padding(.bottom, expanded ? 6 : 12)
    }

    private func button(expanded: Bool) -> some View {
        Button {
            store.activity.isExpanded.toggle()
            store.activity.refresh(store.enabledServices, ifOlderThan: 60)
        } label: {
            HStack(spacing: 6) {
                Text("ACTIVITY")
                    .font(.app(DashboardStyle.captionSize))
                    .tracking(DashboardStyle.captionTracking)
                // Up while closed, down while open: the panel drops down.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 0 : 180))
            }
            .foregroundStyle(DashboardStyle.caption)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide activity" : "Show activity")
    }
}

/// One service: summary, graph, and under it the hovered day and the legend.
private struct ActivityColumn: View {
    let service: Service
    let grid: ActivityGrid?
    let loaded: Bool

    @State private var hovered: ActivityGrid.Day?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let grid {
                SummaryTiles(summary: grid.summary)
                ActivityGraph(grid: grid, service: service, hovered: $hovered)
                HStack(spacing: 8) {
                    Text(hovered.map(Self.dateText) ?? "")
                        .caption()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Legend(service: service)
                }
            } else {
                Text(loaded ? "No activity yet" : "Reading logs…")
                    .font(.app(DashboardStyle.valueSize))
                    .foregroundStyle(DashboardStyle.caption)
            }
        }
        // A new period lays the cells out anew; a day kept from the old one would point
        // at the wrong cell.
        .onChange(of: grid?.layout) { hovered = nil }
    }

    static func dateText(_ day: ActivityGrid.Day) -> String {
        day.date.formatted(.dateTime.locale(.english).weekday(.abbreviated).month(.abbreviated).day().year()).uppercased()
    }
}

/// Tiles in the style of the balances, four to a row: the totals, then tokens by kind.
private struct SummaryTiles: View {
    let summary: ActivitySummary

    /// Wider than the meters' gap, so the tiles do not read as one line of text.
    private static let tileSpacing: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: Self.tileSpacing) {
                tile("TOTAL TOKENS", TokenFormat.count(summary.tokens))
                tile("FAVORITE MODEL", summary.favoriteModel ?? "—")
                tile("MESSAGES", TokenFormat.count(summary.messages))
                tile("PEAK HOUR", summary.peakHourText)
            }
            HStack(alignment: .top, spacing: Self.tileSpacing) {
                tile("INPUT", TokenFormat.count(summary.usage.input))
                tile("OUTPUT", TokenFormat.count(summary.usage.output))
                tile("CACHE WRITE", TokenFormat.count(summary.usage.cacheWrite))
                tile("CACHE READ", TokenFormat.count(summary.usage.cacheRead))
            }
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .caption()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.app(DashboardStyle.tileValueSize))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The cells, drawn in one `Canvas` so hovering redraws one view, not hundreds. Cells
/// grow to fill the column, up to a size per layout; nothing scrolls or is cut off.
private struct ActivityGraph: View {
    let grid: ActivityGrid
    let service: Service
    @Binding var hovered: ActivityGrid.Day?

    /// The column's width once laid out; until then a guess from the dashboard's width.
    @State private var width: CGFloat = BezelPanelController.columnWidth - 2 * ExpandedView.columnPadding

    private var labelHeight: CGFloat { grid.layout == .row ? 16 : 14 }
    /// The week's few labels are larger, to be read at a glance.
    private var labelSize: CGFloat { grid.layout == .row ? 10 : 8.5 }
    private static let rowLabelWidth: CGFloat = 26
    private static let chipHeight: CGFloat = 16

    private var gap: CGFloat { grid.layout == .weeks ? 3 : 4 }
    private var leading: CGFloat { grid.rowLabels.contains { $0 != nil } ? Self.rowLabelWidth : 0 }
    /// Week and month cells stretch across the column at a fixed height; the half-year
    /// grid keeps square cells as big as fit, up to 22 points apart.
    private var stepX: CGFloat {
        let fit = ((width - leading + gap) / CGFloat(max(grid.columns, 1))).rounded(.down)
        return grid.layout == .weeks ? max(6, min(22, fit)) : max(6, fit)
    }
    private var stepY: CGFloat {
        switch grid.layout {
        case .row: 34
        case .calendar: 30
        case .weeks: stepX
        }
    }
    private var cellWidth: CGFloat { stepX - gap }
    private var cellHeight: CGFloat { stepY - gap }
    private var height: CGFloat { labelHeight + CGFloat(grid.rows) * stepY - gap }

    var body: some View {
        ZStack(alignment: .topLeading) {
            columnLabels
            rowLabels
            cells
                .frame(width: CGFloat(grid.columns) * stepX - gap, height: CGFloat(grid.rows) * stepY - gap)
                .offset(x: leading, y: labelHeight)
            chip
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { width = geometry.size.width }
        })
    }

    private var cells: some View {
        let grid = grid
        let stepX = stepX
        let stepY = stepY
        let size = CGSize(width: cellWidth, height: cellHeight)
        let accent = DashboardStyle.accent(for: service)
        let hoveredKey = hovered?.key
        return Canvas { context, _ in
            for (row, days) in grid.cells.enumerated() {
                for (column, day) in days.enumerated() {
                    guard let day else { continue }
                    let rect = CGRect(origin: CGPoint(x: CGFloat(column) * stepX, y: CGFloat(row) * stepY), size: size)
                    let shape = Path(roundedRect: rect, cornerRadius: min(4, min(size.width, size.height) / 5), style: .continuous)
                    context.fill(shape, with: .color(ActivityShade.color(day.level, accent: accent)))
                    if day.key == hoveredKey {
                        context.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover(point)
            case .ended: set(nil)
            }
        }
        // A click shows the day too, in case the panel gets no hover events.
        .onTapGesture { point in hover(point) }
    }

    private func hover(_ point: CGPoint) {
        let column = Int(point.x / stepX)
        let row = Int(point.y / stepY)
        guard point.x >= 0, point.y >= 0, grid.cells.indices.contains(row),
              grid.cells[row].indices.contains(column)
        else { return set(nil) }
        set(grid.cells[row][column])
    }

    /// Only a different day re-renders, not every pixel the cursor moves.
    private func set(_ day: ActivityGrid.Day?) {
        if day?.key != hovered?.key { hovered = day }
    }

    private var columnLabels: some View {
        ForEach(grid.columnLabels.indices, id: \.self) { column in
            if let text = grid.columnLabels[column] {
                Text(text)
                    .caption(size: labelSize)
                    .fixedSize()
                    // Months start at their week; weekdays sit centred over their cells.
                    .frame(width: grid.layout == .weeks ? nil : cellWidth, alignment: grid.layout == .weeks ? .leading : .center)
                    .offset(x: leading + CGFloat(column) * stepX)
            }
        }
    }

    private var rowLabels: some View {
        ForEach(grid.rowLabels.indices, id: \.self) { row in
            if let text = grid.rowLabels[row] {
                Text(text)
                    .caption(size: labelSize)
                    .fixedSize()
                    .frame(height: cellHeight)
                    .offset(y: labelHeight + CGFloat(row) * stepY)
            }
        }
    }

    /// The hovered day's tokens in thousands, just above its cell, kept inside the graph.
    @ViewBuilder
    private var chip: some View {
        if let hovered, let (row, column) = position(of: hovered.key) {
            let text = TokenFormat.thousands(hovered.tokens)
            // The font is monospaced, so the width is known before layout.
            let chipWidth = CGFloat(text.count) * 5.6 + 12
            let centre = leading + CGFloat(column) * stepX + cellWidth / 2
            let x = min(max(centre - chipWidth / 2, 0), width - chipWidth)
            let y = labelHeight + CGFloat(row) * stepY - Self.chipHeight - 3
            Text(text)
                .font(.app(9))
                .monospacedDigit()
                .foregroundStyle(.white)
                .fixedSize()
                .frame(width: chipWidth, height: Self.chipHeight)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(white: 0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(DashboardStyle.accent(for: service).opacity(0.6), lineWidth: 1)
                        )
                )
                .offset(x: x, y: y)
                .allowsHitTesting(false)
        }
    }

    private func position(of key: DayKey) -> (Int, Int)? {
        for (row, days) in grid.cells.enumerated() {
            if let column = days.firstIndex(where: { $0?.key == key }) { return (row, column) }
        }
        return nil
    }
}

private struct Legend: View {
    let service: Service

    var body: some View {
        HStack(spacing: 3) {
            Text("LESS").caption(size: 8.5).padding(.trailing, 3)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ActivityShade.color(level, accent: DashboardStyle.accent(for: service)))
                    .frame(width: 10, height: 10)
            }
            Text("MORE").caption(size: 8.5).padding(.leading, 3)
        }
    }
}

enum ActivityShade {
    /// Opacity of the service's colour for shades 1...4.
    static let opacities: [Double] = [0.28, 0.5, 0.74, 1]

    static func color(_ level: Int, accent: Color) -> Color {
        level == 0 ? Color.white.opacity(0.07) : accent.opacity(opacities[level - 1])
    }
}
