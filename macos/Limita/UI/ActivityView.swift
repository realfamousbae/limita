import SwiftUI

/// A shared period, with each provider choosing its own chart.
struct ActivitySection: View {
    let store: LimitsStore

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(store.enabledServices.enumerated()), id: \.element) { index, service in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.08))
                        .frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 12)
                }
                column(service, showsPeriod: index == 0)
                    .padding(.horizontal, ExpandedView.columnPadding)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column(_ service: Service, showsPeriod: Bool) -> some View {
        let history = service.kind == .balance ? store.spendHistory(service) : nil
        let offersModels = history?.hasModelBreakdown == true
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if showsPeriod {
                    ChartSwitch(values: ActivityPeriod.allCases, selection: Binding(
                        get: { store.activity.period }, set: { store.activity.period = $0 }
                    ), label: "Period", title: \.title)
                }
                if offersModels {
                    ChartSwitch(values: SpendingMode.allCases, selection: Binding(
                        get: { store.spendingModes[service] ?? .money },
                        set: { store.spendingModes[service] = $0 }
                    ), label: "\(service.displayName) graph", title: \.title)
                }
            }
            .frame(height: 24)

            if service.kind == .balance {
                SpendingColumn(service: service, history: history,
                               mode: offersModels ? (store.spendingModes[service] ?? .money) : .money,
                               period: store.activity.period)
            } else if !service.usesProviderConnection {
                ActivityColumn(service: service, grid: store.activity.grids[service],
                               loaded: store.activity.isLoaded, activity: store.activity)
            }
        }
    }
}

/// Both controls use the same capsule, typography and selection treatment.
private struct ChartSwitch<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let label: String
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                let selected = selection == value
                Button {
                    selection = value
                } label: {
                    Text(title(value))
                        .font(.app(DashboardStyle.captionSize))
                        .tracking(DashboardStyle.captionTracking)
                        .foregroundStyle(selected ? Color.white : DashboardStyle.caption)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A small capsule at the bottom right of the dashboard, in line with the columns'
/// right edge, that opens and closes the panel below it. The folded meters' capsules
/// share its line, each under its own column.
struct ActivityToggle: View {
    let store: LimitsStore
    var showButton = true

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
                    if showButton && service == store.enabledServices.last {
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

    func button(expanded: Bool) -> some View {
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
    let activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let grid {
                SummaryTiles(items: [
                    ("TOTAL TOKENS", TokenFormat.count(grid.summary.tokens)),
                    ("FAVORITE MODEL", grid.summary.favoriteModel ?? "—"),
                    ("PEAK HOUR", grid.summary.peakHourText),
                    ("INPUT", TokenFormat.count(grid.summary.usage.input)),
                    ("OUTPUT", TokenFormat.count(grid.summary.usage.output)),
                    ("CACHE READ", TokenFormat.count(grid.summary.usage.cacheRead)),
                ])
                ActivityCalendar(grid: grid, service: service) { width in
                    activity.setGraphWidth(width, for: service)
                }
            } else {
                Text(loaded ? "No activity yet" : "Reading logs…")
                    .font(.app(DashboardStyle.valueSize))
                    .foregroundStyle(DashboardStyle.caption)
            }
        }
    }
}

struct ActivityCalendar: View {
    let grid: ActivityGrid
    let service: Service
    var chipText: (ActivityGrid.Day) -> String = { TokenFormat.thousands($0.tokens) }
    var dayDetails: ((ActivityGrid.Day) -> String?)?
    let onWidthChange: (CGFloat) -> Void

    @State private var hovered: ActivityGrid.Day?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityGraph(grid: grid, service: service, hovered: $hovered,
                          chipText: chipText, onWidthChange: onWidthChange)
            HStack(spacing: 8) {
                Text(hovered.map(Self.dateText) ?? "")
                    .caption()
                    .lineLimit(1)
                Spacer(minLength: 0)
                Legend(service: service)
            }
            if let dayDetails {
                Text(hovered.flatMap(dayDetails) ?? " ")
                    .caption()
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .onChange(of: grid.layout) { hovered = nil }
    }

    static func dateText(_ day: ActivityGrid.Day) -> String {
        day.date.formatted(.dateTime.locale(.english).weekday(.abbreviated).month(.abbreviated).day().year()).uppercased()
    }
}

/// Three evenly spaced summary tiles per row.
struct SummaryTiles: View {
    let items: [(label: String, value: String)]

    private static let tileSpacing: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                HStack(alignment: .top, spacing: Self.tileSpacing) {
                    ForEach(start..<min(start + 3, items.count), id: \.self) { index in
                        tile(items[index].label, items[index].value)
                    }
                }
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
/// use fixed square cells for weeks; the number of weeks follows the column width.
private struct ActivityGraph: View {
    let grid: ActivityGrid
    let service: Service
    @Binding var hovered: ActivityGrid.Day?
    let chipText: (ActivityGrid.Day) -> String
    let onWidthChange: (CGFloat) -> Void

    /// The column's width once laid out; until then a guess from the dashboard's width.
    @State private var width: CGFloat = BezelPanelController.columnWidth - 2 * ExpandedView.columnPadding
    @FocusState private var keyboardFocused: Bool

    private var labelHeight: CGFloat { grid.layout == .row ? 16 : 14 }
    /// The week's few labels are larger, to be read at a glance.
    private var labelSize: CGFloat { grid.layout == .row ? 10 : 8.5 }
    private static let rowLabelWidth: CGFloat = 26
    private static let chipHeight: CGFloat = 16

    private var gap: CGFloat { grid.layout == .weeks ? 3 : 4 }
    private var leading: CGFloat { grid.rowLabels.contains { $0 != nil } ? Self.rowLabelWidth : 0 }
    /// Weekly cells are square and retain their size as the column changes width.
    private var stepX: CGFloat {
        let fit = ((width - leading + gap) / CGFloat(max(grid.columns, 1))).rounded(.down)
        return grid.layout == .weeks ? 22 : max(6, fit)
    }
    private var stepY: CGFloat {
        switch grid.layout {
        case .row: 34
        case .calendar: 30
        case .weeks: 22
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
                .onAppear { updateWidth(geometry.size.width) }
                .onChange(of: geometry.size.width) { updateWidth(geometry.size.width) }
        })
    }

    private func updateWidth(_ value: CGFloat) {
        width = value
        onWidthChange(value)
        hovered = nil
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
        .focusable()
        .focused($keyboardFocused)
        .accessibilityLabel("Daily calendar")
        .accessibilityValue(hovered.map { "\(ActivityCalendar.dateText($0)), \(chipText($0))" } ?? "")
        .onChange(of: keyboardFocused) { _, focused in
            if focused && hovered == nil {
                set(grid.cells.flatMap { $0.compactMap { $0 } }.max(by: { $0.key < $1.key }))
            } else if !focused {
                set(nil)
            }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            switch press.key {
            case .leftArrow: move(row: 0, column: -1)
            case .rightArrow: move(row: 0, column: 1)
            case .upArrow: move(row: -1, column: 0)
            case .downArrow: move(row: 1, column: 0)
            default: return .ignored
            }
            return .handled
        }
    }

    private func move(row: Int, column: Int) {
        guard let hovered, let position = position(of: hovered.key) else {
            set(grid.cells.flatMap { $0.compactMap { $0 } }.max(by: { $0.key < $1.key }))
            return
        }
        let nextRow = position.0 + row
        let nextColumn = position.1 + column
        if grid.cells.indices.contains(nextRow), grid.cells[nextRow].indices.contains(nextColumn),
           let day = grid.cells[nextRow][nextColumn] {
            set(day)
        }
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

    /// The hovered day's value, just above its cell and kept inside the graph.
    @ViewBuilder
    private var chip: some View {
        if let hovered, let (row, column) = position(of: hovered.key) {
            let text = chipText(grid.cells[row][column] ?? hovered)
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
