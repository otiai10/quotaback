import SwiftUI
import AppKit
import Charts
import Combine

/// The single Analytics window. Opening it again brings the existing one to the front
@MainActor
final class AnalyticsWindowController: NSObject, NSWindowDelegate {
    private let store: UsageStore
    private var window: NSWindow?
    private var titleSubscription: AnyCancellable?

    init(store: UsageStore) {
        self.store = store
        super.init()
        // Follow `language` in config.json
        titleSubscription = store.$config.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.window?.title = L10n.analytics }
        }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = L10n.analytics
        store.analyticsVisible = true
        // An accessory app isn't active on its own, so the window would open behind others
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = AnalyticsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: AnalyticsView(store: store))
        window.setContentSize(NSSize(width: 640, height: 760))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        store.analyticsVisible = false
    }
}

/// An accessory app has no main menu, so ⌘W isn't bound to Close unless the window handles it
private final class AnalyticsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct AnalyticsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ScrollView(.vertical) {
            AnalyticsCharts(input: store.analytics)
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

/// The three charts, stacked. Takes plain data so that it can be rendered without the app
struct AnalyticsCharts: View {
    let input: AnalyticsInput

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            card(L10n.analyticsFinalUsage, L10n.analyticsFinalUsageNote) { finalUsage }
            card(L10n.analyticsBurndown, L10n.analyticsBurndownNote) { burndown }
        }
        .padding(20)
    }

    private func card<Content: View>(_ title: String, _ note: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func empty() -> some View {
        Text(L10n.analyticsNoData)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }

    // MARK: 1

    @ViewBuilder private var finalUsage: some View {
        // The most recent weeks only, so that the cells keep a readable width
        let all = AnalyticsModel.heatmap(input.cycles, now: input.now, titles: input.title)
        let shown = Set(Set(all.map(\.week)).sorted().suffix(Self.heatmapWeeks))
        let cells = all.filter { shown.contains($0.week) }
        if cells.isEmpty {
            empty()
        } else {
            let rows = cells.map(\.row).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let weeks = Set(cells.map(\.week)).sorted()
            let byID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(weeks, id: \.self) { w in
                        Text(Self.shortDay(w)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        let first = cells.first { $0.row == row }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(first?.account ?? row).font(.caption)
                            Text(first?.window ?? "").font(.caption2).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .gridColumnAlignment(.leading)
                        ForEach(weeks, id: \.self) { w in
                            HeatCellView(cell: byID["\(row) \(w.timeIntervalSince1970)"])
                        }
                    }
                }
            }
        }
    }

    private static let heatmapWeeks = 8

    private static func shortDay(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .omitted, time: .omitted).month(.defaultDigits).day().locale(L10n.locale))
    }

    // MARK: 2

    @ViewBuilder private var burndown: some View {
        let points = AnalyticsModel.burndown(input.live, titles: input.title)
        if points.isEmpty {
            empty()
        } else {
            // Explicit colors so that the limit labels (plain views, not marks) can match their lines
            let labels = points.map(\.label).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let color = { (label: String) in Self.seriesColors[(labels.firstIndex(of: label) ?? 0) % Self.seriesColors.count] }
            let marks = AnalyticsModel.limitMarks(points)
            Chart {
                LineMark(x: .value(L10n.analyticsElapsed, 0), y: .value("%", 0), series: .value("Line", "ideal"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                LineMark(x: .value(L10n.analyticsElapsed, 100), y: .value("%", 100), series: .value("Line", "ideal"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                ForEach(points) { p in
                    LineMark(x: .value(L10n.analyticsElapsed, p.elapsed), y: .value("%", p.percent),
                             series: .value("Line", "\(p.series) \(p.kind)"))
                        .foregroundStyle(by: .value("Window", p.label))
                        .lineStyle(p.kind == .projected ? StrokeStyle(lineWidth: 1.5, dash: [2, 3]) : StrokeStyle(lineWidth: 2))
                    if p.kind == .observed {
                        PointMark(x: .value(L10n.analyticsElapsed, p.elapsed), y: .value("%", p.percent))
                            .foregroundStyle(by: .value("Window", p.label))
                            .symbolSize(16)
                    }
                }
            }
            .chartForegroundStyleScale(domain: labels, range: labels.map(color))
            .chartXScale(domain: 0...100)
            .chartYScale(domain: 0...100)
            .chartXAxisLabel(L10n.analyticsElapsed)
            .chartYAxis { AxisMarks(position: .leading) }
            .chartYAxisLabel(L10n.analyticsUsage, position: .leading)
            .chartLegend(position: .bottom, alignment: .leading)
            // Above the end of each tail, nudged sideways only where labels would overlap or leave the chart
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plot = geo[proxy.plotAreaFrame]
                    let xs = AnalyticsModel.spread(marks.map { plot.minX + (proxy.position(forX: $0.elapsed) ?? 0) },
                                                   width: Self.limitLabelWidth, within: 0...geo.size.width)
                    ForEach(Array(zip(marks, xs)), id: \.0.id) { m, x in
                        limitLabel(m, color: color(m.label))
                            .position(x: x, y: plot.minY - Self.limitLabelHeight / 2 - 2)
                    }
                }
            }
            .frame(height: 240)
            .padding(.top, marks.isEmpty ? 0 : Self.limitLabelHeight + 2)
        }
    }

    /// When the tail hits 100%: the day over the time, in the line's color. Hover for the reset and how much earlier
    private func limitLabel(_ m: AnalyticsModel.LimitMark, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(Self.limitFormat("M/d (E)", m.at))
            Text(Self.limitFormat("HH:mm", m.at))
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(color)
        .fixedSize()
        .help(L10n.analyticsLimitHelp(WindowRow.format(m.at), L10n.duration(m.resetsAt.timeIntervalSince(m.at)),
                                      WindowRow.format(m.resetsAt)))
    }

    /// Room a limit label takes, a little more than "12/30 (Wed)" so that neighbors keep a gap
    private static let limitLabelWidth: CGFloat = 72
    private static let limitLabelHeight: CGFloat = 26
    private static let seriesColors: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .yellow]

    /// The parts of the panel's "M/d (E) HH:mm"
    private static func limitFormat(_ format: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = format
        return f.string(from: d)
    }

}

/// One week of one window: darker for more of the limit used, outlined at 100%, striped when it's a lower bound,
/// faint and empty when there's no data (a week before the window existed has no cell at all)
private struct HeatCellView: View {
    let cell: AnalyticsModel.HeatCell?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        ZStack {
            if let cell {
                if let p = cell.percent {
                    let level = min(1, max(0, p / 100))
                    shape.fill(Color.accentColor.opacity(0.12 + 0.88 * level))
                    if cell.isLowerBound { Stripes().stroke(Color.primary.opacity(0.25), lineWidth: 1).clipShape(shape) }
                    if p >= 100 { shape.strokeBorder(Color.primary, lineWidth: 1.5) }
                    Text("\(cell.isLowerBound ? "≥" : "")\(Int(p.rounded()))")
                        .font(.caption.monospacedDigit().weight(p >= 100 ? .bold : .regular))
                        .foregroundStyle(level >= 0.55 ? Color.white : Color.primary)
                } else {
                    shape.fill(Color.secondary.opacity(0.08))
                    Text("–").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
    }
}

/// Diagonal hatching for lower-bound cells
private struct Stripes: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
