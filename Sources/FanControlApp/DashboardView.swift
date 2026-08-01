import SwiftUI
import Charts
import FanKit

struct DashboardView: View {
    @ObservedObject var model: StatusModel
    // Launch straight into a tab: `--curves` / `--sensors`.
    @State private var tab: Tab = {
        if CommandLine.arguments.contains("--curves") { return .curves }
        if CommandLine.arguments.contains("--sensors") { return .sensors }
        return .overview
    }()

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case curves = "Curves"
        case sensors = "Sensors"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: return "chart.xyaxis.line"
            case .curves:   return "point.topleft.down.curvedto.point.bottomright.up"
            case .sensors:  return "square.grid.2x2"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            // Every tab fills. Without this the hosting view reports each
            // tab's own fitting height and the window physically resizes when
            // you switch between them — Curves came out 85pt shorter than
            // Overview.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Raised from 560: the charts fill rather than scroll now, so the
        // floor has to be the point below which they stop being readable.
        .frame(minWidth: 900, minHeight: 600)
        .background(.background)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Metric.sm) {
            HStack(spacing: Metric.xxs) {
                ForEach(Tab.allCases) { item in
                    tabButton(item)
                }
            }
            .padding(Metric.xxs)
            .background {
                RoundedRectangle(cornerRadius: Metric.radiusMd, style: .continuous)
                    .fill(Palette.cardFill)
            }

            Spacer(minLength: Metric.md)

            // The right of the toolbar carries whatever this tab needs and
            // nothing it already shows. On Overview the hero cards state these
            // four numbers 40pt lower, so repeating them here is pure noise —
            // the time range takes the slot instead. On the other tabs there
            // are no vitals on screen at all, so the chips earn their place.
            if tab == .overview {
                windowPicker
            } else if let status = model.status {
                HStack(spacing: Metric.sm) {
                    headlineStat("cpu", String(format: "%.0f°", status.cpuTemperature),
                                 Palette.temperature(status.cpuTemperature))
                    headlineStat("display", String(format: "%.0f°", status.gpuTemperature),
                                 Palette.temperature(status.gpuTemperature))
                    headlineStat("fanblades", "\(Int(status.averageFanRPM))",
                                 Palette.fan(status.fans.first?.info.loadFraction ?? 0))
                    headlineStat("gauge.medium", String(format: "%.0f%%", status.cpu.busy * 100),
                                 .secondary)
                }
            }

            sourceBadge
        }
        .padding(.horizontal, Metric.md)
        .padding(.vertical, Metric.sm)
    }

    private var windowPicker: some View {
        HStack(spacing: Metric.xxs) {
            ForEach(StatusModel.HistoryWindow.allCases) { window in
                let active = model.historyWindow == window
                Button {
                    model.historyWindow = window
                    model.loadHistory()
                } label: {
                    Text(window.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 34)
                        .padding(.vertical, Metric.xxs + 1)
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .background {
                            Capsule(style: .continuous)
                                .fill(active ? Color.primary.opacity(0.09) : .clear)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Metric.xxs)
        .background { Capsule(style: .continuous).fill(Palette.cardFill) }
    }

    private func tabButton(_ item: Tab) -> some View {
        let active = tab == item
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { tab = item }
        } label: {
            HStack(spacing: Metric.xs) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(item.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(width: 96)
            .padding(.vertical, Metric.xs + 1)
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .background {
                // Concentric with the 13pt container radius minus its 3pt inset.
                RoundedRectangle(cornerRadius: Metric.concentric(outer: Metric.radiusMd,
                                                                 inset: Metric.xxs),
                                 style: .continuous)
                    .fill(active ? Color.primary.opacity(0.09) : .clear)
            }
        }
        .buttonStyle(.plain)
    }

    private func headlineStat(_ symbol: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: Metric.xs) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, Metric.sm)
        .padding(.vertical, Metric.xs)
        .background {
            Capsule(style: .continuous).fill(Palette.cardFill)
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch model.source {
        case .daemon:
            Chip(text: "Live", symbol: "checkmark.circle.fill", color: .green, emphasised: true)
                .help("fand is running — fan control available")
        case .local:
            Chip(text: "Monitor", symbol: "eye", color: .secondary)
                .help("Reading sensors directly. Install the helper to control fans.")
        case .connecting:
            ProgressView().controlSize(.small)
        case .unavailable:
            Chip(text: "No SMC", symbol: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: OverviewView(model: model)
        case .curves:   CurveEditorView(model: model)
        case .sensors:  SensorsView(model: model)
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        // No ScrollView. A dashboard that scrolls has already failed at being
        // a dashboard; below the minimum window size the charts compress
        // instead, which keeps everything on one screen.
        VStack(alignment: .leading, spacing: Metric.md) {
            if let status = model.status {
                heroRow(status)
            }

            if model.history.isEmpty {
                placeholder
                Spacer(minLength: 0)
            } else {
                charts
            }
        }
        .padding(Metric.md)
    }

    // MARK: Hero

    /// The two card kinds hold a different number of rows — a fan has a meter
    /// under its value, a sensor group has its mean — so their natural heights
    /// differ by a few points. Left alone the row centres them, which both
    /// staggers the five headers and makes the cards look mismatched.
    ///
    /// `maxHeight: .infinity` on each card stretches them all to the tallest;
    /// `fixedSize` keeps the row itself at that height rather than letting it
    /// go greedy and fight the charts below for the window.
    private func heroRow(_ status: SystemStatus) -> some View {
        HStack(alignment: .top, spacing: Metric.sm) {
            ForEach(status.fans) { fan in
                heroFan(fan).frame(maxHeight: .infinity)
            }
            ForEach([SensorGroup.cpu, .gpu, .hotspot], id: \.self) { group in
                if let summary = status.group(group) {
                    heroTemperature(group, summary).frame(maxHeight: .infinity)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Shared top line: glyph, tracked-out name, and one quiet fact on the
    /// right. Both card kinds use it, so the row scans as one object.
    private func heroHeader(symbol: String, title: String, trailing: String) -> some View {
        HStack(spacing: Metric.xs) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .bold)).tracking(0.6)
            Spacer(minLength: Metric.xs)
            Text(trailing).font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private func heroFan(_ fan: FanState) -> some View {
        let info = fan.info
        let color = fan.safetyEngaged ? Color.orange : Palette.fan(info.loadFraction)
        return Card(padding: Metric.sm + 2, radius: Metric.radiusMd + 2,
                    tint: fan.safetyEngaged ? .orange : nil) {
            VStack(alignment: .leading, spacing: Metric.xs + 1) {
                heroHeader(symbol: "fanblades",
                           title: "FAN \(info.index)",
                           trailing: info.mode.displayName)

                HStack(alignment: .bottom, spacing: Metric.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Metric.xxs) {
                        Text("\(Int(info.actualRPM))")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("rpm").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: Metric.xs)
                    Sparkline(values: fanTrend(info.index), color: color,
                              minimumSpan: 400)
                        .frame(minWidth: Metric.sparkMinWidth,
                               maxWidth: Metric.sparkMaxWidth,
                               minHeight: Metric.sparkHeight,
                               maxHeight: Metric.sparkHeight)
                }

                HStack(spacing: Metric.sm) {
                    Meter(fraction: info.loadFraction, color: color)
                    // Wide enough for "100%" — at 30 it wrapped, which grew the
                    // card and knocked the whole hero row out of alignment.
                    Text("\(Int(info.loadFraction * 100))%")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .frame(width: Metric.xl, alignment: .trailing)
                }

                // Absorbs the slack when this card is the shorter of the two
                // kinds, so every header in the row sits on the same line.
                Spacer(minLength: 0)
            }
        }
    }

    private func heroTemperature(_ group: SensorGroup, _ summary: GroupSummary) -> some View {
        let color = Palette.temperature(summary.max)
        return Card(padding: Metric.sm + 2, radius: Metric.radiusMd + 2) {
            VStack(alignment: .leading, spacing: Metric.xs + 1) {
                heroHeader(symbol: group.symbol,
                           title: group.displayName.uppercased(),
                           trailing: "\(summary.count) sensors")

                HStack(alignment: .bottom, spacing: Metric.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: Metric.xxs) {
                            Text(String(format: "%.0f", summary.max))
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(color)
                            Text("°C").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }

                        // The headline is the hottest die, because that is
                        // what throttles. The mean beside it separates one hot
                        // sensor from a whole cluster running warm.
                        Text("mean \(String(format: "%.0f°", summary.mean))")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: Metric.xs)
                    Sparkline(values: temperatureTrend(group), color: color,
                              minimumSpan: 5)
                        // Taller than the fan card's: it spans two text rows.
                        .frame(minWidth: Metric.sparkMinWidth,
                               maxWidth: Metric.sparkMaxWidth,
                               minHeight: Metric.xl,
                               maxHeight: Metric.xl)
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Trends

    private func fanTrend(_ index: Int) -> [Double] {
        model.history.compactMap { index < $0.fanRPM.count ? $0.fanRPM[index] : nil }
    }

    /// Zeros mean "not sampled", not "ice cold" — leaving them in would drag
    /// the sparkline's own min down and flatten every real movement.
    private func temperatureTrend(_ group: SensorGroup) -> [Double] {
        let series: [Double]
        switch group {
        case .gpu:     series = model.history.map(\.gpuCelsius)
        case .hotspot: series = model.history.map(\.hotspotCelsius)
        default:       series = model.history.map(\.cpuCelsius)
        }
        return series.filter { $0 > 0 }
    }

    // MARK: Charts

    private var placeholder: some View {
        Card(padding: Metric.xl, radius: Metric.radiusLg) {
            VStack(spacing: Metric.sm) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No history yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("A sample is recorded every 5 seconds.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metric.lg)
        }
    }

    /// Height a chart card adds around its plot: padding top and bottom, the
    /// header row, and the gap between them. The golden split is of the
    /// *plotting* area, so the chrome has to come off first — otherwise the
    /// visible traces end up in some ratio that isn't the one we asked for.
    private static let cardChrome: CGFloat = (Metric.sm + 2) * 2 + 14 + Metric.sm

    private var charts: some View {
        GeometryReader { geometry in
            // Temperature is the primary trace and takes φ/(1+φ) of the plot
            // height; fan speed and load share the remainder. At the default
            // window this lands within a few points of 233 : 144, and it stays
            // golden at every other size instead of leaving a dead band at the
            // bottom the way two fixed heights did.
            let plot = geometry.size.height - Self.cardChrome * 2 - Metric.sm
            let tall = max(Metric.plotShort,
                           (plot * Metric.phi / (1 + Metric.phi)).rounded())
            let short = max(Metric.plotFloor, plot - tall)

            VStack(spacing: Metric.sm) {
                temperatureChart(height: tall)
                HStack(spacing: Metric.sm) {
                    fanChart(height: short)
                    loadChart(height: short)
                }
            }
        }
    }

    /// Y range follows the data rather than starting at zero. Nothing on this
    /// machine ever runs below ~30 °C, so a zero-based axis would spend half
    /// its height on empty space and flatten every meaningful movement.
    /// Rounded out to 5° so the gridlines land on numbers worth reading.
    private var temperatureDomain: ClosedRange<Double> {
        let values = model.history.flatMap {
            [$0.cpuCelsius, $0.gpuCelsius]
        }.filter { $0 > 0 }
        guard let low = values.min(), let high = values.max() else { return 40...100 }
        let lower = ((low - 3) / 5).rounded(.down) * 5
        let upper = ((high + 3) / 5).rounded(.up) * 5
        return lower...max(upper, lower + 10)
    }

    /// Hotspot is deliberately absent. The `Tf*` group on this machine sits at
    /// 93–95 °C under any load at all, so plotting it here draws a dead-flat
    /// line at the ceiling and stretches the domain ~30 % wider than the two
    /// traces that actually move. Its value, mean and trend are all on the
    /// hotspot hero card, which is where a constant belongs.
    private static let temperatureSeries = [
        LegendEntry(name: "CPU", color: .blue),
        LegendEntry(name: "GPU", color: .purple),
    ]

    private func temperatureChart(height: CGFloat) -> some View {
        chartCard("Temperature", symbol: "thermometer.medium", unit: "°C",
                  height: height, legend: Self.temperatureSeries) {
            Chart {
                ForEach(model.history, id: \.timestamp) { sample in
                    LineMark(x: .value("Time", sample.timestamp),
                             y: .value("°C", sample.cpuCelsius),
                             series: .value("Series", "CPU"))
                        .foregroundStyle(by: .value("Series", "CPU"))
                    LineMark(x: .value("Time", sample.timestamp),
                             y: .value("°C", sample.gpuCelsius),
                             series: .value("Series", "GPU"))
                        .foregroundStyle(by: .value("Series", "GPU"))
                }
            }
            // Three stacked area fills turn into one muddy block. Lines only.
            .chartYScale(domain: temperatureDomain)
            // Drawn in the card header instead — see `LegendDot`.
            .chartLegend(.hidden)
            .chartForegroundStyleScale(domain: Self.temperatureSeries.map(\.name),
                                       range: Self.temperatureSeries.map(\.color))
            .chartSymbolSizeScale(domain: 0...1, range: 0...0)
        }
    }

    /// Anchored to the hardware's real range so the trace sits where the fan
    /// actually is within its envelope, instead of auto-scaling every wobble
    /// into a dramatic-looking swing.
    private var fanDomain: ClosedRange<Double> {
        guard let info = model.status?.fans.first?.info, info.maxRPM > info.minRPM else {
            return 2000...8000
        }
        return info.minRPM...info.maxRPM
    }

    private static func fanColor(_ index: Int) -> Color {
        index == 0 ? .teal : .cyan
    }

    private static func fanFill(_ index: Int) -> LinearGradient {
        let color = fanColor(index)
        return LinearGradient(colors: [color.opacity(0.18), color.opacity(0.01)],
                              startPoint: .top, endPoint: .bottom)
    }

    /// The `%.1fk` axis format: "7 000" with a group separator is three glyphs
    /// of noise on an axis this narrow.
    private static let rpmAxisFormat: (Double) -> String = {
        String(format: "%.1fk", $0 / 1000)
    }

    /// Flattened ahead of the `Chart` body. Nesting two `ForEach`es over
    /// `enumerated()` and emitting two mark types inside them defeats the
    /// type checker outright — it gives up rather than inferring the result.
    private struct FanPoint: Identifiable {
        let id: String
        let time: Date
        let rpm: Double
        let fan: Int
    }

    private var fanPoints: [FanPoint] {
        model.history.flatMap { sample in
            sample.fanRPM.enumerated().map { index, rpm in
                FanPoint(id: "\(index)@\(sample.timestamp.timeIntervalSince1970)",
                         time: sample.timestamp, rpm: rpm, fan: index)
            }
        }
    }

    private func fanChart(height: CGFloat) -> some View {
        // Explicit floor rather than the implicit zero baseline. The height of
        // the shading then reads directly as "how much of this fan's range is
        // in use", which is the whole reason the domain is pinned to the
        // hardware instead of auto-scaling.
        //
        // It also sidesteps a trap: a plain `y:` AreaMark stacks the two fans
        // to ~15 600 RPM, double the domain ceiling, and Swift Charts does not
        // clip to the plot — the fill escapes the card and paints over the
        // chart above it. A yStart/yEnd range area has nothing to stack.
        let floor = fanDomain.lowerBound

        return chartCard("Fan speed", symbol: "fanblades", unit: "RPM",
                         height: height, yFormat: Self.rpmAxisFormat) {
            Chart(fanPoints) { point in
                AreaMark(x: .value("Time", point.time),
                         yStart: .value("Floor", floor),
                         yEnd: .value("RPM", point.rpm),
                         series: .value("Fan", point.fan))
                    .foregroundStyle(Self.fanFill(point.fan))

                LineMark(x: .value("Time", point.time),
                         y: .value("RPM", point.rpm),
                         series: .value("Fan", point.fan))
                    .foregroundStyle(Self.fanColor(point.fan))
            }
            .chartYScale(domain: fanDomain)
        }
    }

    private func loadChart(height: CGFloat) -> some View {
        chartCard("CPU load", symbol: "gauge.medium", unit: "%", height: height) {
            Chart {
                ForEach(model.history, id: \.timestamp) { sample in
                    AreaMark(x: .value("Time", sample.timestamp),
                             y: .value("%", sample.cpuBusy * 100))
                        .foregroundStyle(
                            LinearGradient(colors: [.accentColor.opacity(0.28),
                                                    .accentColor.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", sample.timestamp),
                             y: .value("%", sample.cpuBusy * 100))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .chartYScale(domain: 0...100)
        }
    }

    private func chartCard<C: View>(
        _ title: String, symbol: String, unit: String,
        height: CGFloat,
        legend: [LegendEntry] = [],
        yFormat: @escaping (Double) -> String = { String(format: "%.0f", $0) },
        @ViewBuilder chart: () -> C
    ) -> some View {
        Card(padding: Metric.sm + 2, radius: Metric.radiusMd + 2) {
            VStack(alignment: .leading, spacing: Metric.sm) {
                // Fixed height: `cardChrome` budgets against it, and a header
                // that grows by a point when a legend appears would throw the
                // golden split off by the same amount.
                HStack(spacing: Metric.md) {
                    SectionLabel(text: title, symbol: symbol)
                    Spacer(minLength: Metric.sm)
                    ForEach(legend) { LegendDot(entry: $0) }
                    Text(unit)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                .frame(height: 14)

                chart()
                    .frame(height: height)
                    .chartXAxis {
                        AxisMarks(preset: .aligned) { _ in
                            AxisGridLine().foregroundStyle(Palette.trackFill)
                            AxisValueLabel()
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(Palette.trackFill)
                            AxisValueLabel {
                                if let raw = value.as(Double.self) {
                                    Text(yFormat(raw))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
            }
        }
    }
}

// MARK: - Sensors

struct SensorsView: View {
    @ObservedObject var model: StatusModel
    @State private var sensors: [SensorReading] = []
    @State private var query = ""

    private var filtered: [SensorGroup: [SensorReading]] {
        let matching = query.isEmpty
            ? sensors
            : sensors.filter { $0.key.localizedCaseInsensitiveContains(query) }
        return Dictionary(grouping: matching, by: \.group)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metric.md) {
                    ForEach(SensorGroup.allCases, id: \.self) { group in
                        if let items = filtered[group], !items.isEmpty {
                            section(group, items)
                        }
                    }
                }
                .padding(Metric.md)
            }
        }
        .onAppear(perform: reload)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            reload()
        }
    }

    private var searchBar: some View {
        HStack(spacing: Metric.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Filter by key — try Tp0, Tg, Tf", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Chip(text: "\(sensors.count) live")
        }
        .padding(.horizontal, Metric.md)
        .padding(.vertical, Metric.sm)
    }

    private func section(_ group: SensorGroup, _ items: [SensorReading]) -> some View {
        let values = items.map(\.celsius)
        let peak = values.max() ?? 0

        return VStack(alignment: .leading, spacing: Metric.sm) {
            HStack(spacing: Metric.sm) {
                Image(systemName: group.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.temperature(peak))
                Text(group.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Chip(text: "\(items.count)")
                Spacer()
                Text(String(format: "peak %.1f°C", peak))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.temperature(peak))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: Metric.sm)],
                      spacing: Metric.sm) {
                ForEach(items.sorted { $0.celsius > $1.celsius }) { reading in
                    HStack(spacing: Metric.xs) {
                        Text(reading.key)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Metric.xxs)
                        Text(String(format: "%.1f", reading.celsius))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.temperature(reading.celsius))
                    }
                    .padding(.horizontal, Metric.sm)
                    .padding(.vertical, Metric.xs)
                    .background {
                        RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                            .fill(Palette.cardFill)
                    }
                }
            }
        }
    }

    private func reload() {
        Task { @MainActor in
            sensors = await fetchSensors()
        }
    }

    private func fetchSensors() async -> [SensorReading] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let client = FanControlClient()
                if let response = try? client.send(Request(cmd: .sensors)),
                   let sensors = response.sensors {
                    continuation.resume(returning: sensors)
                } else {
                    // No daemon — fall back to reading the SMC in-process.
                    continuation.resume(returning: (try? LocalMonitor())?.readSensors() ?? [])
                }
            }
        }
    }
}
