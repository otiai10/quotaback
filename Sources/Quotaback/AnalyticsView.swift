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
            card(L10n.analyticsBalance, L10n.analyticsBalanceNote) { balance }
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

    /// Opacity of a bar whose value is a lower bound (same in both bar charts)
    private static let lowerBoundOpacity = 0.35

    private static func percentText(_ v: Double, lowerBound: Bool) -> String {
        "\(lowerBound ? "≥" : "")\(Int(v.rounded()))%"
    }

    private static func day(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(L10n.locale))
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
            .chartXScale(domain: 0...100)
            .chartYScale(domain: 0...100)
            .chartXAxisLabel(L10n.analyticsElapsed)
            .chartYAxis { AxisMarks(position: .leading) }
            .chartYAxisLabel(L10n.analyticsUsage, position: .leading)
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 240)
        }
    }

    // MARK: 3

    @ViewBuilder private var balance: some View {
        let bars = AnalyticsModel.balance(input.cycles, titles: input.title)
        if bars.isEmpty {
            empty()
        } else {
            Chart(bars) { bar in
                BarMark(x: .value("Week", Self.day(bar.week)), y: .value("%", bar.percent))
                    .foregroundStyle(by: .value("Account", bar.title))
                    .position(by: .value("Account", bar.title))
                    .opacity(bar.isLowerBound ? Self.lowerBoundOpacity : 1)
                    .annotation(position: .top) {
                        Text(Self.percentText(bar.percent, lowerBound: bar.isLowerBound))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }
            .chartYScale(domain: 0...110)
            .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 200)
        }
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
