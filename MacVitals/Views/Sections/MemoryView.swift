import SwiftUI

/// Memory page, top to bottom: a plain-language verdict driven by pressure (not "used %"),
/// the four numbers that matter, history of RAM in use + overflow to disk, what memory is
/// made of, and who's using it.
struct MemoryView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Router.self) private var router
    @AppStorage(SettingsKeys.historyRange) private var rangeRaw = HistoryRange.hour.rawValue

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .hour }

    var body: some View {
        SectionScroll {
            verdict.entrance()
            stats.entrance(delay: 0.04)
            adequacy.entrance(delay: 0.08)
            // Both cards take the height of the taller one.
            HStack(alignment: .top, spacing: 16) {
                FreeUpMemoryCard()
                topApps
            }
            .fixedSize(horizontal: false, vertical: true)
            .entrance(delay: 0.12)
            history.entrance(delay: 0.16)

            underTheHoodHeader
            technicalStats
            composition
        }
    }

    // MARK: Verdict

    private var verdict: some View {
        let memory = monitor.memory
        let level = MemoryInsights.level(pressure: memory.pressure, swapUsed: memory.swapUsed)
        let tint = Theme.memoryLevel(level)
        let top = monitor.apps.filter { !$0.isCurrentApp && $0.kind != .system }.max { $0.memory < $1.memory }
        let fraction = memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0

        return HStack(spacing: 22) {
            ZStack {
                GaugeRing(fraction: min(1, fraction), color: tint, lineWidth: 12)
                // Number and unit on separate lines so it never wraps mid-value:
                // "12.4" big, "of 16 GB" small (the unit reads across both).
                VStack(spacing: 0) {
                    Text(Fmt.gigabytesNumber(memory.used))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()

                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("of \(Fmt.gigabytesNumber(memory.total, digits: 0)) GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your memory is \(level.title)")
                    .font(.title2.weight(.semibold))
                    .contentTransition(.interpolate)
                    .animation(.smooth, value: level)
                Text(level.sentence)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let top, top.memory > 0 {
                        InfoChip(text: "Mostly \(top.name) · \(Fmt.memory(top.memory))",
                                 icon: "app", bundlePath: top.bundlePath)
                    }
                    if memory.swapUsed >= MemoryInsights.notableSwap {
                        InfoChip(text: "\(Fmt.memory(memory.swapUsed)) overflowed to disk",
                                 icon: "arrow.down.to.line", tint: .orange)
                            .help("When RAM runs out, macOS moves memory to the SSD (swap). It's much slower than RAM, and heavy use wears the SSD.")
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
        let memory = monitor.memory
        return HStack(spacing: 16) {
            DetailStat(
                label: "In use", term: "Used",
                value: Fmt.memory(memory.used),
                caption: "of \(Fmt.memory(memory.total)). A high number is normal.",
                help: "App memory + wired + compressed. macOS deliberately keeps RAM busy, so this is usually high. Watch pressure instead."
            )
            DetailStat(
                label: "Pressure", term: "Memory pressure",
                value: pressureTitle(memory.pressure),
                tint: memory.pressure == .normal ? .green : Theme.pressure(memory.pressure),
                caption: pressureCaption(memory.pressure),
                help: "How hard macOS is working to make everything fit. The single best memory health signal."
            )
            DetailStat(
                label: "Ready to reuse", term: "Cached files",
                value: Fmt.memory(memory.cached),
                caption: "Freed instantly when apps need it",
                help: "Recently used files kept in RAM to open faster. Counts as available."
            )
            DetailStat(
                label: "Overflow to disk", term: "Swap",
                value: memory.swapUsed == 0 ? "None" : Fmt.memory(memory.swapUsed),
                tint: memory.swapUsed >= MemoryInsights.notableSwap ? .orange : nil,
                caption: memory.swapUsed == 0 ? "Everything fits in RAM" : "Much slower than RAM",
                help: "Memory moved to the SSD because RAM ran out. A little is normal; gigabytes mean you're short on RAM."
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pressureTitle(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }

    private func pressureCaption(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Everything fits comfortably"
        case .warning: "Compressing to make room"
        case .critical: "Out of RAM, using the disk"
        }
    }

    // MARK: History

    private var history: some View {
        let total = Double(monitor.memory.total)
        let samples = monitor.history(for: range)
        let inUse = samples.map { $0.memoryUsedPercent / 100 * total }
        let typical = inUse.isEmpty ? nil : inUse.reduce(0, +) / Double(inUse.count)
        let peak = inUse.max()
        let peakSwap = samples.compactMap(\.swapUsed).max() ?? 0
        let start = monitor.historyStart
        let partial = start.map { $0 > Date().addingTimeInterval(-range.duration + range.resolution * 2) } ?? true

        let inUsePoints = monitor.points(\.memoryUsedPercent, series: "In use", range: range).map {
            ChartPoint(date: $0.date, value: $0.value / 100 * total, series: $0.series, segment: $0.segment)
        }
        let swapPoints = monitor.points(\.swapUsed, series: "Overflow to disk", range: range)

        return Card("History", systemImage: "chart.xyaxis.line", tint: Theme.memory) {
            HistoryChart(
                points: inUsePoints + swapPoints,
                series: [.init(name: "In use", color: Theme.memory), .init(name: "Overflow to disk", color: .orange)],
                range: range,
                stacked: true,
                reference: total > 0 ? .init(label: "Installed", value: total) : nil,
                format: { Fmt.memory(UInt64(max(0, $0))) }
            )
            .frame(height: 210)
            Text(peakSwap >= Double(MemoryInsights.notableSwap)
                 ? "Orange above the purple means RAM ran out and memory overflowed to the disk."
                 : "No meaningful overflow to disk in the \(range.longLabel). Your RAM has been enough.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if partial, let start {
                Label("Collecting since \(start.formatted(date: range == .hour || range == .day ? .omitted : .abbreviated, time: .shortened)). History builds up while Mac Vitals runs.",
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } accessory: {
            HStack(spacing: 14) {
                if let typical, let peak {
                    summaryValue("Typical", Fmt.memory(UInt64(typical)))
                    summaryValue("Peak", Fmt.memory(UInt64(peak)))
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

    // MARK: Is your RAM enough?

    private var adequacy: some View {
        let result = MemoryInsights.adequacy(samples: monitor.history(for: .month))
        let installed = monitor.memory.total
        let tint: Color = switch result {
        case .collecting: .secondary
        case .plenty: .green
        case .mostlyEnough: Theme.memory
        case .oftenShort: .orange
        }
        return Card("Is your RAM enough?", systemImage: "memorychip.fill", tint: Theme.memory) {
            HStack(alignment: .center, spacing: 20) {
                if let comfortable = result.comfortablePercent {
                    // Share of time memory was comfortable vs tight.
                    VStack(alignment: .leading, spacing: 6) {
                        SegmentedBar(segments: [
                            .init(label: "Comfortable", value: comfortable, color: .green),
                            .init(label: "Tight", value: 100 - comfortable, color: .orange),
                        ], height: 12)
                        HStack(spacing: 12) {
                            legend("Comfortable \(Fmt.percent(comfortable))", color: .green)
                            legend("Tight \(Fmt.percent(100 - comfortable))", color: .orange)
                        }
                    }
                    .frame(width: 220)
                } else {
                    Image(systemName: "hourglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(MemoryInsights.headline(result, installed: installed))
                        .font(.headline)
                        .foregroundStyle(tint == .secondary ? .primary : tint)
                    Text(MemoryInsights.explanation(result))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let advice = MemoryInsights.nextMacAdvice(result, installed: installed) {
                        Label(advice, systemImage: "laptopcomputer")
                            .font(.callout.weight(.medium))
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        } accessory: {
            if result.comfortablePercent != nil, let start = monitor.historyStart {
                Text("Based on your Mac since \(start.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: Under the hood

    private var underTheHoodHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Under the hood")
                .font(.title3.weight(.semibold))
            Text("How macOS is managing memory right now, for when you want the technical details.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    private var technicalStats: some View {
        let memory = monitor.memory
        let swapActivity = memory.swapInRate + memory.swapOutRate
        return HStack(spacing: 16) {
            DetailStat(
                label: "Swap activity", term: "Swap in/out",
                value: Fmt.rate(swapActivity),
                tint: swapActivity > 5_000_000 ? .orange : nil,
                caption: swapActivity > 0 ? "In \(Fmt.rate(memory.swapInRate)) · Out \(Fmt.rate(memory.swapOutRate))" : "Nothing moving to or from disk",
                help: "Memory being moved between RAM and the SSD right now. Sustained activity means your Mac is short on RAM (\"thrashing\")."
            )
            DetailStat(
                label: "Page-outs", term: "Pageouts",
                value: Fmt.rate(memory.pageOutRate),
                caption: "Memory written out to make room",
                help: "Rate at which macOS evicts memory pages to disk. Near zero is healthy."
            )
            DetailStat(
                label: "Compression", term: "Compressor",
                value: memory.compressionRatio.map { String(format: "%.1f×", $0) } ?? "—",
                caption: memory.compressionRatio != nil
                    ? "\(Fmt.memory(memory.compressedOriginal)) squeezed into \(Fmt.memory(memory.compressed))"
                    : "Nothing compressed right now",
                help: "Before using the disk, macOS compresses memory it isn't using. It's fast and saves RAM."
            )
            DetailStat(
                label: "System", term: "Wired",
                value: Fmt.memory(memory.wired),
                caption: "Locked by macOS; can't be freed",
                help: "Memory the kernel and drivers need at all times."
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Composition

    private var composition: some View {
        let memory = monitor.memory
        let slices = MemoryInsights.composition(memory)
        return Card("What memory is made of", systemImage: "square.stack.3d.up", tint: Theme.memory) {
            SegmentedBar(
                segments: slices.map { .init(label: $0.name, value: Double($0.bytes), color: color(for: $0.id)) },
                height: 16
            )
            VStack(spacing: 10) {
                ForEach(slices) { slice in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(for: slice.id))
                            .frame(width: 10, height: 10)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(slice.name).font(.callout.weight(.medium))
                                if slice.term != slice.name {
                                    Text(slice.term.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .tracking(0.5)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(Fmt.memory(slice.bytes)).monospacedDigit()
                                Text(Fmt.percent(MemoryInsights.shareOfRAM(slice.bytes, total: memory.total)))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            Text(slice.meaning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func color(for sliceID: String) -> Color {
        switch sliceID {
        case "app": Theme.memory
        case "wired": .orange
        case "compressed": .pink
        case "cached": .blue.opacity(0.6)
        default: .gray.opacity(0.35)
        }
    }

    // MARK: Top apps

    private var topApps: some View {
        let total = monitor.memory.total
        let ranked = Array(monitor.apps.sorted { $0.memory > $1.memory }.prefix(8))
        let maxBytes = Double(max(ranked.first?.memory ?? 1, 1))
        return Card("What's using memory", systemImage: "list.number", tint: Theme.memory) {
            VStack(spacing: 10) {
                if ranked.isEmpty {
                    Text("Collecting data…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(ranked) { app in
                    HStack(spacing: 10) {
                        AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(app.name).lineLimit(1)
                                if app.isCurrentApp { ThisAppBadge() }
                                Spacer()
                                Text(Fmt.memory(app.memory)).monospacedDigit()
                                Text("\(Fmt.percent(MemoryInsights.shareOfRAM(app.memory, total: total))) of RAM")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 72, alignment: .trailing)
                            }
                            MeterBar(fraction: Double(app.memory) / maxBytes, tint: Theme.memory, height: 4)
                        }
                    }
                    .help("\(app.name): \(Fmt.memory(app.memory)) across \(app.processCount) process\(app.processCount == 1 ? "" : "es")")
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

// MARK: - Free up memory

/// Heavy apps you haven't used in a while, with what quitting them would give back.
private struct FreeUpMemoryCard: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppActivity.self) private var activity
    @State private var confirmingID: String?

    var body: some View {
        let suggestions = MemoryInsights.closeSuggestions(
            apps: monitor.apps,
            lastUsed: { activity.lastUsed(bundlePath: $0) },
            trackingSince: activity.trackingSince
        )
        let freeable = suggestions.reduce(UInt64(0)) { $0 + $1.app.memory }
        let learning = Date().timeIntervalSince(activity.trackingSince) < MemoryInsights.suggestionIdleTime

        Card("Free up memory", systemImage: "wand.and.sparkles", tint: Theme.memory) {
            if learning {
                Text("Mac Vitals is learning which apps you use. In a few minutes it'll suggest heavy apps you haven't touched in a while.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if suggestions.isEmpty {
                Label("Nothing to suggest. Everything big that's open has been used recently.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("~\(Fmt.memory(freeable))")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.memory)
                        Text("could be freed by quitting apps you're not using")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    VStack(spacing: 2) {
                        ForEach(suggestions) { suggestion in
                            SuggestionRow(
                                suggestion: suggestion,
                                trackingSince: activity.trackingSince,
                                isConfirming: confirmingID == suggestion.id,
                                onRequestQuit: { confirmingID = suggestion.id },
                                onConfirm: {
                                    ProcessController.quit(suggestion.app, force: false)
                                    confirmingID = nil
                                },
                                onCancel: { confirmingID = nil }
                            )
                        }
                    }
                }
            }
        }
        .fillingHeight()
    }
}

private struct SuggestionRow: View {
    let suggestion: MemoryInsights.CloseSuggestion
    let trackingSince: Date
    let isConfirming: Bool
    let onRequestQuit: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var hovering = false

    var body: some View {
        let app = suggestion.app
        HStack(spacing: 10) {
            AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(isConfirming ? "Quit \(app.name)?" : app.name)
                    .font(.callout.weight(isConfirming ? .semibold : .regular))
                    .lineLimit(1)
                Text(MemoryInsights.describeLastUsed(suggestion.lastUsed, trackingSince: trackingSince))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if isConfirming {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerStyle(.link)
                    .keyboardShortcut(.cancelAction)
                Button("Quit", role: .destructive, action: onConfirm)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .pointerStyle(.link)
            } else {
                Text(Fmt.memory(app.memory)).font(.callout).monospacedDigit()
                Button("Quit", action: onRequestQuit)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerStyle(.link)
                    .opacity(hovering ? 1 : 0.6)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(isConfirming ? Color.red.opacity(0.08) : Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3), value: isConfirming)
    }
}
