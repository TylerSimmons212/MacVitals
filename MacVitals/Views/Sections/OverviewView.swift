import SwiftUI

struct OverviewView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Router.self) private var router

    var body: some View {
        SectionScroll {
            header
            // Both columns stretch to the taller of the two, so the health card always
            // lines up exactly with the tile grid regardless of how many tiles there are.
            HStack(alignment: .top, spacing: 16) {
                HealthCard(report: monitor.health) { router.section = $0 }
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .entrance()
                tileGrid
                    .frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)

            Card("Busiest Apps", systemImage: "flame", tint: .orange) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CPU").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        TopAppsList(apps: monitor.apps, metric: .cpu, limit: 6)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Memory").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        TopAppsList(apps: monitor.apps, metric: .memory, limit: 6)
                    }
                }
            } accessory: {
                Button("All Apps") { router.section = .apps }
                    .buttonStyle(.glass)
                    .pointerStyle(.link)
                    .controlSize(.small)
            }
            .entrance(delay: 0.3)
        }
    }

    private var header: some View {
        let info = monitor.info
        return HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.hostName).font(.title2.weight(.semibold))
                Text("\(info.chip) · \(info.coreSummary) · \(Fmt.memory(info.physicalMemory)) · \(info.osVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Uptime").font(.caption).foregroundStyle(.secondary)
                Text(Fmt.duration(info.uptime)).font(.callout.weight(.medium)).monospacedDigit()
            }
        }
    }

    /// Two-column grid built from rows so rows can share extra height evenly
    /// (LazyVGrid rows can't stretch).
    private var tileGrid: some View {
        let tiles = tileKinds
        let rows = stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
        return VStack(spacing: 16) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 16) {
                    ForEach(rows[rowIndex], id: \.self) { kind in
                        tile(kind)
                            .entrance(delay: 0.05 * Double(tiles.firstIndex(of: kind) ?? 0) + 0.05)
                    }
                    if rows[rowIndex].count == 1 {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var tileKinds: [DashboardSection] {
        var kinds: [DashboardSection] = [.cpu, .memory, .disk, .network]
        if monitor.battery != nil { kinds.append(.battery) }
        return kinds
    }

    @ViewBuilder
    private func tile(_ kind: DashboardSection) -> some View {
        let open = { router.section = kind }
        switch kind {
        case .cpu:
            MetricTile(title: "CPU", icon: "cpu", tint: Theme.cpu,
                       value: Fmt.percent(monitor.cpu.total),
                       caption: "User \(Fmt.percent(monitor.cpu.user)) · System \(Fmt.percent(monitor.cpu.system))",
                       action: open) {
                CoreStrip(values: monitor.cpu.perCore, tint: Theme.cpu)
            }
        case .memory:
            MetricTile(title: "Memory", icon: "memorychip", tint: Theme.memory,
                       value: Fmt.percent(monitor.memory.usedPercent),
                       caption: "\(Fmt.memory(monitor.memory.used)) of \(Fmt.memory(monitor.memory.total)) · \(monitor.memory.pressure.label) pressure",
                       action: open) {
                MemoryComposition(memory: monitor.memory)
            }
        case .disk:
            MetricTile(title: "Disk", icon: "internaldrive", tint: Theme.disk,
                       value: "\(Fmt.bytes(monitor.disk.availableCapacity)) free",
                       caption: "Read \(Fmt.rate(monitor.disk.readRate)) · Write \(Fmt.rate(monitor.disk.writeRate))",
                       action: open) {
                CapacityGauge(usedFraction: monitor.disk.usedPercent / 100, tint: Theme.disk)
            }
        case .network:
            MetricTile(title: "Network", icon: "network", tint: Theme.network,
                       value: Fmt.rate(monitor.network.downloadRate),
                       caption: "Upload \(Fmt.rate(monitor.network.uploadRate))",
                       action: open) {
                NetworkLevels(download: monitor.network.downloadRate, upload: monitor.network.uploadRate)
            }
        default:
            if let battery = monitor.battery {
                MetricTile(title: "Battery", icon: "battery.75percent", tint: Theme.battery,
                           value: Fmt.percent(battery.percent),
                           caption: batteryCaption(battery),
                           action: open) {
                    BatteryGlyph(percent: battery.percent, charging: battery.isCharging, tint: Theme.battery)
                }
            }
        }
    }

    private func batteryCaption(_ battery: BatterySnapshot) -> String {
        if let minutes = battery.minutesRemaining {
            return "\(battery.statusText) · \(Fmt.duration(TimeInterval(minutes * 60))) \(battery.isCharging ? "to full" : "left")"
        }
        return battery.statusText
    }
}

struct HealthCard: View {
    let report: HealthReport
    var onSelect: (DashboardSection) -> Void

    var body: some View {
        let tint = Theme.health(report.score)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                HealthRing(score: report.score)
                    .frame(width: 112, height: 112)
                    .shadow(color: tint.opacity(0.4), radius: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.grade)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.interpolate)
                        .animation(.smooth, value: report.grade)
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Vital Signs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            // Rows share the remaining height evenly so the card fills to match the grid.
            VStack(spacing: 6) {
                ForEach(report.checks) { check in
                    VitalRow(check: check) { onSelect(check.section) }
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: report.checks)
        }
        .cardStyle(padding: 18, tint: tint, fillHeight: true)
    }

    private var summary: String {
        guard let top = report.issues.first else { return "Every vital sign is in the healthy range." }
        let others = report.issues.count - 1
        return others > 0 ? "\(top.title), plus \(others) more." : "\(top.title)."
    }
}

/// One factor of the health score: status light, name, current value.
private struct VitalRow: View {
    let check: HealthCheck
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = check.severity.map(Theme.severity) ?? .green
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: check.severity.map(Theme.severityIcon) ?? "checkmark.circle.fill")
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
                Text(check.label)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(check.value)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(check.severity == nil ? .secondary : color)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .background {
                if check.severity != nil || hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.opacity(check.severity != nil ? 0.12 : 0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(check.severity == nil ? "\(check.label) is healthy" : "Open \(check.section.title)")
    }
}
