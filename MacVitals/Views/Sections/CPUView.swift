import SwiftUI

/// CPU page, top to bottom: a plain-language verdict, the four numbers that matter (friendly
/// name + technical term), history against your typical level, cores by type, and who's using it.
struct CPUView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Router.self) private var router
    @AppStorage(SettingsKeys.historyRange) private var rangeRaw = HistoryRange.hour.rawValue

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .hour }
    private var cores: Int { max(monitor.cpu.perCore.count, monitor.info.logicalCores) }

    var body: some View {
        SectionScroll {
            verdict.entrance()
            stats.entrance(delay: 0.05)
            history.entrance(delay: 0.1)
            // Both cards take the height of the taller one.
            HStack(alignment: .top, spacing: 16) {
                coresCard
                topApps
            }
            .fixedSize(horizontal: false, vertical: true)
            .entrance(delay: 0.15)
        }
    }

    // MARK: Verdict

    private var verdict: some View {
        let cpu = monitor.cpu
        let recent = monitor.recentAverage(\.cpuTotal, over: 20)
        let level = CPUInsights.level(forAverage: recent > 0 ? recent : cpu.total)
        let tint = Theme.cpuLevel(level)
        // Name what's loading *your* Mac, never ourselves (we're busiest simply because you're looking).
        let top = monitor.apps.filter { !$0.isCurrentApp }.max { $0.cpu < $1.cpu }
        let topShare = top.map { CPUInsights.shareOfTotal(appCPU: $0.cpu, cores: cores) } ?? 0
        let bottleneck = CPUInsights.singleCoreBottleneck(perCore: cpu.perCore, total: cpu.total)
        let throttled = monitor.thermal == .serious || monitor.thermal == .critical

        return HStack(spacing: 22) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(1, cpu.total / 100))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: cpu.total)
                VStack(spacing: 0) {
                    Text(Fmt.percent(cpu.total))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .rollingNumber(Int(cpu.total))
                    Text("in use").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your CPU is \(level.title.lowercased())")
                    .font(.title2.weight(.semibold))
                    .contentTransition(.interpolate)
                    .animation(.smooth, value: level)
                Text(level.sentence + (throttled ? " macOS is slowing it down to cool off." : ""))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let top, topShare >= 2 {
                        InfoChip(
                            text: top.kind == .system
                                ? "Mostly macOS · \(Fmt.percent(topShare))"
                                : "Mostly \(top.name) · \(Fmt.percent(topShare))",
                            icon: top.kind == .system ? "apple.logo" : "app",
                            bundlePath: top.bundlePath
                        )
                    }
                    if let bottleneck {
                        InfoChip(text: "Core \(bottleneck + 1) is maxed out", icon: "exclamationmark.triangle.fill", tint: .orange)
                            .help("One core is at full speed while the rest are quiet. Usually a single app stuck on one task. It's slow no matter how many cores you have.")
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    // MARK: Stats

    private var stats: some View {
        let cpu = monitor.cpu
        let load = cpu.loadAverage
        let demand = CPUInsights.demand(loadAverage: load.first ?? 0, cores: cores)
        let thermal = monitor.thermal
        return HStack(spacing: 16) {
            DetailStat(
                label: "Apps", term: "User",
                value: Fmt.percent(cpu.user, digits: 1),
                caption: "Work done for your apps",
                help: "CPU time spent running app code (user mode)."
            )
            DetailStat(
                label: "macOS", term: "System",
                value: Fmt.percent(cpu.system, digits: 1),
                caption: "Work done by the system itself",
                help: "CPU time spent in the macOS kernel: drivers, file system, networking."
            )
            DetailStat(
                label: "Demand", term: "Load avg",
                value: demand.title,
                tint: demand == .heavy ? .orange : nil,
                caption: "\(load.map { String(format: "%.2f", $0) }.joined(separator: " · ")) on \(cores) cores",
                help: "Tasks running or waiting, averaged over 1, 5 and 15 minutes. Above \(cores) (your core count) means work is queuing."
            )
            DetailStat(
                label: "Temperature", term: "Thermal",
                value: thermal.label,
                tint: thermal == .nominal ? nil : Theme.thermal(thermal),
                caption: thermal == .nominal || thermal == .fair ? "No throttling" : "Slowing down to cool off",
                help: "macOS reduces CPU speed when the Mac gets too hot."
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: History

    private var history: some View {
        let samples = monitor.history(for: range)
        let totals = samples.map(\.cpuTotal)
        let typical = totals.isEmpty ? nil : totals.reduce(0, +) / Double(totals.count)
        let peak = totals.max()
        let start = monitor.historyStart
        let partial = start.map { $0 > Date().addingTimeInterval(-range.duration + range.resolution * 2) } ?? true

        return Card("History", systemImage: "chart.xyaxis.line", tint: Theme.cpu) {
            HistoryChart(
                points: monitor.points(\.cpuSystem, series: "macOS", range: range)
                    + monitor.points(\.cpuUser, series: "Apps", range: range),
                series: [.init(name: "macOS", color: Theme.cpuSystem), .init(name: "Apps", color: Theme.cpu)],
                range: range,
                yMax: 100,
                stacked: true,
                reference: typical.map { .init(label: "Typical", value: $0) }
            )
            .frame(height: 210)
            if partial, let start {
                Label("Collecting since \(start.formatted(date: range == .hour || range == .day ? .omitted : .abbreviated, time: .shortened)). History builds up while Mac Vitals runs.",
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } accessory: {
            HStack(spacing: 14) {
                if let typical, let peak {
                    summaryValue("Typical", Fmt.percent(typical))
                    summaryValue("Peak", Fmt.percent(peak))
                }
                HistoryRangePicker()
            }
        }
    }

    private func summaryValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    // MARK: Cores

    private var coresCard: some View {
        let perCore = monitor.cpu.perCore
        let clusters = CPUInsights.clusters(coreCount: perCore.count,
                                            efficiency: monitor.info.efficiencyCores,
                                            performance: monitor.info.performanceCores)
        return Card("Cores", systemImage: "square.grid.3x3", tint: Theme.cpu) {
            ForEach(clusters, id: \.name) { cluster in
                let values = Array(perCore[cluster.range])
                let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(cluster.name) · \(values.count)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("avg \(Fmt.percent(average))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    CoreGrid(values: values, firstIndex: cluster.range.lowerBound)
                }
            }
            if clusters.count > 1 {
                Text("Efficiency cores handle background tasks on very little power. Performance cores take over for demanding work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fillingHeight()
    }

    // MARK: Top apps

    private var topApps: some View {
        let ranked = Array(monitor.apps.sorted { $0.cpu > $1.cpu }.prefix(8))
        let maxShare = max(ranked.first.map { CPUInsights.shareOfTotal(appCPU: $0.cpu, cores: cores) } ?? 0, 0.1)
        return Card("What's using the CPU", systemImage: "list.number", tint: Theme.cpu) {
            VStack(spacing: 10) {
                if ranked.isEmpty {
                    Text("Collecting data…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(ranked) { app in
                    let share = CPUInsights.shareOfTotal(appCPU: app.cpu, cores: cores)
                    HStack(spacing: 10) {
                        AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(app.name).lineLimit(1)
                                if app.isCurrentApp { ThisAppBadge() }
                                Spacer()
                                Text(Fmt.percent(share, digits: 1))
                                    .monospacedDigit()
                                Text(String(format: "%.2f cores", app.cpu / 100))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 64, alignment: .trailing)
                            }
                            MeterBar(fraction: share / maxShare, tint: Theme.cpu, height: 4)
                        }
                    }
                    .help("\(app.name): \(Fmt.percent(share, digits: 1)) of total CPU (\(Fmt.percent(app.cpu)) of one core) across \(app.processCount) process\(app.processCount == 1 ? "" : "es")")
                }
            }
        } accessory: {
            Button("All Apps") { router.section = .apps }
                .buttonStyle(.glass)
                .controlSize(.small)
                .pointerStyle(.link)
        }
        .fillingHeight()
    }
}

struct CoreGrid: View {
    let values: [Double]
    var firstIndex = 0

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 44), spacing: 8)], spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.load(value).gradient)
                                .frame(height: max(2, proxy.size.height * min(1, value / 100)))
                        }
                    }
                    .frame(height: 56)
                    .animation(.smooth, value: value)
                    Text("\(firstIndex + index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Core \(firstIndex + index + 1): \(Fmt.percent(value))")
            }
        }
    }
}
