import SwiftUI

/// Battery page. For everyone: is the battery healthy, what's it doing right now (and why),
/// what's draining it, and how long a charge really lasts for how *you* use your Mac.
/// Under the hood: capacity in mAh, voltage, current, charger and power draw history.
struct BatteryView: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage(SettingsKeys.historyRange) private var rangeRaw = HistoryRange.hour.rawValue

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .hour }

    var body: some View {
        if let battery = monitor.battery {
            SectionScroll {
                verdict(battery).entrance()
                stats(battery).entrance(delay: 0.04)
                HStack(alignment: .top, spacing: 16) {
                    drainCard(battery)
                    lifeCard(battery)
                }
                .fixedSize(horizontal: false, vertical: true)
                .entrance(delay: 0.08)
                healthCard(battery).entrance(delay: 0.12)
                history.entrance(delay: 0.16)

                underTheHoodHeader
                technicalStats(battery)
                powerHistory
            }
        } else {
            ContentUnavailableView(
                "No Battery",
                systemImage: "powerplug",
                description: Text("This Mac runs on AC power, so there's no battery to monitor.")
            )
        }
    }

    // MARK: Verdict

    private func verdict(_ battery: BatterySnapshot) -> some View {
        let health = BatteryInsights.health(percent: battery.healthPercent, condition: battery.condition)
        let state = BatteryInsights.chargingState(battery)
        let chargeTint: Color = battery.percent < 20 ? .red : (battery.isCharging ? Theme.network : Theme.battery)
        let tint = Theme.batteryHealth(health)

        return HStack(spacing: 22) {
            ZStack {
                Circle().stroke(chargeTint.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(1, battery.percent / 100))
                    .stroke(chargeTint.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: battery.percent)
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(String(format: "%.0f", battery.percent))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .rollingNumber(Int(battery.percent))
                        Text("%").font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    Image(systemName: battery.isCharging ? "bolt.fill" : (battery.isPluggedIn ? "powerplug.fill" : "battery.75percent"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                Text(health.title)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.interpolate)
                    .animation(.smooth, value: health)
                Text(BatteryInsights.healthSentence(battery))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    InfoChip(text: BatteryInsights.chargingText(state),
                             icon: chargingIcon(state),
                             tint: state == .pluggedNotCharging ? .orange : .secondary)
                        .help(BatteryInsights.chargingHelp(state))
                    if let top = monitor.apps.filter({ !$0.isCurrentApp }).max(by: { $0.watts < $1.watts }),
                       !battery.isPluggedIn, top.watts >= 1 {
                        InfoChip(text: "Biggest drain: \(top.name)", icon: "app", bundlePath: top.bundlePath)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    private func chargingIcon(_ state: BatteryInsights.ChargingState) -> String {
        switch state {
        case .charging: "bolt.fill"
        case .holdingToProtect: "leaf.fill"
        case .full: "checkmark.circle"
        case .pluggedNotCharging: "powerplug"
        case .onBattery: "clock"
        }
    }

    // MARK: Stats

    private func stats(_ battery: BatterySnapshot) -> some View {
        HStack(spacing: 16) {
            DetailStat(
                label: "Charge", term: "Level",
                value: Fmt.percent(battery.percent),
                tint: battery.percent < 20 ? .red : nil,
                caption: battery.statusText
            )
            DetailStat(
                label: battery.isCharging ? "Until full" : "Time left", term: "Estimate",
                value: battery.minutesRemaining.map { Fmt.duration(TimeInterval($0 * 60)) } ?? "—",
                caption: battery.minutesRemaining == nil ? (battery.isPluggedIn ? "Plugged in" : "macOS is estimating…") : "macOS's estimate right now",
                help: "Based on how much power your Mac is using this moment, so it moves around. \"Battery life\" below uses your usual pace instead."
            )
            DetailStat(
                label: battery.isCharging ? "Charging power" : "Power use", term: "Watts",
                value: battery.watts.map { String(format: "%.1f W", abs($0)) } ?? "—",
                caption: battery.isCharging
                    ? (battery.adapterWatts.map { "From a \($0) W charger" } ?? "Charging")
                    : (battery.isPluggedIn ? "Running on the charger" : "Drawn from the battery"),
                help: "How much power is flowing out of (or into) the battery right now."
            )
            DetailStat(
                label: "Health", term: "Max capacity",
                value: battery.healthPercent.map { Fmt.percent($0) } ?? "—",
                tint: (battery.healthPercent ?? 100) < 80 ? .orange : nil,
                caption: battery.cycleCount.map { "\($0) charge cycles" } ?? (battery.condition ?? ""),
                help: "How much charge the battery can hold compared with when it was new. Matches System Settings › Battery."
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: What's draining it

    private func drainCard(_ battery: BatterySnapshot) -> some View {
        let ranked = Array(monitor.apps.filter { $0.watts >= 0.05 }.sorted { $0.watts > $1.watts }.prefix(8))
        let maxWatts = max(ranked.first?.watts ?? 1, 0.1)
        return Card("What's using your battery", systemImage: "bolt.batteryblock", tint: Theme.battery) {
            if battery.isPluggedIn {
                Text("You're plugged in. This is what would drain your battery if you weren't.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                if ranked.isEmpty {
                    Text("Nothing is using much power right now.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(ranked) { app in
                    let impact = BatteryInsights.impact(watts: app.watts)
                    HStack(spacing: 10) {
                        AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(app.name).lineLimit(1)
                                if app.isCurrentApp { ThisAppBadge() }
                                Spacer()
                                Text(impact.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(impact == .high ? .orange : .secondary)
                                Text(String(format: "%.1f W", app.watts))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 46, alignment: .trailing)
                            }
                            MeterBar(fraction: app.watts / maxWatts, tint: impact == .high ? .orange : Theme.battery, height: 4)
                        }
                    }
                    .help("\(app.name) is drawing about \(String(format: "%.2f", app.watts)) W, measured by macOS's own per-app energy accounting.")
                }
            }
        }
        .fillingHeight()
    }

    // MARK: Battery life

    private func lifeCard(_ battery: BatterySnapshot) -> some View {
        let typical = BatteryInsights.typicalDrain(samples: monitor.history(for: .month), sampleLength: 900)
            ?? BatteryInsights.typicalDrain(samples: monitor.history(for: .day), sampleLength: 60)
        let fullWh = battery.fullChargeWattHours
        let usualHours = BatteryInsights.hours(fullChargeWattHours: fullWh, watts: typical)
        let nowHours = battery.isPluggedIn ? nil : BatteryInsights.hours(fullChargeWattHours: fullWh, watts: battery.watts)

        return Card("Battery life", systemImage: "hourglass", tint: Theme.battery) {
            VStack(alignment: .leading, spacing: 14) {
                if let usualHours {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A full charge lasts")
                            .foregroundStyle(.secondary)
                        Text(BatteryInsights.describe(hours: usualHours))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.battery)
                        Text("at how you usually use your Mac (\(String(format: "%.1f W", typical ?? 0)) on average).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Mac Vitals learns your usual battery life after about an hour of unplugged use.", systemImage: "hourglass.bottomhalf.filled")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let nowHours {
                    Divider()
                    HStack {
                        Text("At this moment's pace")
                        Spacer()
                        Text(BatteryInsights.describe(hours: nowHours))
                            .monospacedDigit()
                            .foregroundStyle(usualHours.map { nowHours < $0 * 0.7 } == true ? .orange : .primary)
                    }
                    .font(.callout)
                    if let usualHours, nowHours < usualHours * 0.7 {
                        Text("You're draining faster than usual. Check \"What's using your battery\".")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let fullWh {
                    Text(String(format: "A full charge holds about %.0f Wh today.", fullWh))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .fillingHeight()
    }

    // MARK: Health

    private func healthCard(_ battery: BatterySnapshot) -> some View {
        let health = BatteryInsights.health(percent: battery.healthPercent, condition: battery.condition)
        let rated = battery.designCycleCount ?? 1000
        return Card("Battery health", systemImage: "heart.text.square", tint: Theme.battery) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    healthBar(
                        title: "Capacity",
                        value: battery.healthPercent.map { "\(Fmt.percent($0)) of original" } ?? "—",
                        fraction: (battery.healthPercent ?? 0) / 100,
                        tint: (battery.healthPercent ?? 100) < 80 ? .orange : Theme.battery,
                        marker: 0.8,
                        caption: capacityCaption(battery)
                    )
                    healthBar(
                        title: "Charge cycles",
                        value: battery.cycleCount.map { "\($0) of ~\(rated.formatted())" } ?? "—",
                        fraction: Double(battery.cycleCount ?? 0) / Double(rated),
                        tint: Double(battery.cycleCount ?? 0) > Double(rated) * 0.8 ? .orange : Theme.battery,
                        marker: nil,
                        caption: "One cycle = using 100% of the battery's charge, even across several days."
                    )
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text(health == .serviceSoon ? "What to do" : "Keep it healthy")
                        .font(.subheadline.weight(.semibold))
                    ForEach(tips(for: health), id: \.self) { tip in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(.tertiary).frame(width: 4, height: 4)
                            Text(tip).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } accessory: {
            if let condition = battery.condition {
                Text("Condition: \(condition)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func capacityCaption(_ battery: BatterySnapshot) -> String {
        guard let design = battery.designCapacity, let full = battery.maxCapacity else {
            return "Apple recommends service below 80%."
        }
        return "Holds \(full.formatted()) mAh; it held \(design.formatted()) mAh when new. Service is recommended below 80%."
    }

    private func healthBar(title: String, value: String, fraction: Double, tint: Color, marker: Double?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(value).font(.callout).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint.gradient).frame(width: proxy.size.width * min(1, max(0, fraction)))
                    if let marker {
                        Rectangle().fill(.primary.opacity(0.35)).frame(width: 1.5, height: proxy.size.height + 6)
                            .offset(x: proxy.size.width * marker)
                            .help("80%: Apple's service threshold")
                    }
                }
            }
            .frame(height: 10)
            .animation(.smooth(duration: 0.8), value: fraction)
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tips(for health: BatteryInsights.Health) -> [String] {
        switch health {
        case .serviceSoon:
            return [
                "Your battery holds noticeably less than new. An Apple Store or authorized provider can replace it.",
                "Until then, keep a charger handy and use Low Power Mode on the go.",
            ]
        default:
            return [
                "Keep Optimized Battery Charging on (System Settings › Battery). It pauses around 80% to slow aging.",
                "Heat ages batteries fastest. Avoid charging in hot places or under blankets.",
                "It's fine to leave it plugged in; macOS manages the charge for you.",
            ]
        }
    }

    // MARK: History

    private var history: some View {
        Card("Charge history", systemImage: "chart.xyaxis.line", tint: Theme.battery) {
            HistoryChart(
                points: monitor.points(\.batteryPercent, series: "Charge", range: range),
                series: [.init(name: "Charge", color: Theme.battery)],
                range: range,
                yMax: 100
            )
            .frame(height: 190)
        } accessory: {
            HistoryRangePicker()
        }
    }

    // MARK: Under the hood

    private var underTheHoodHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Under the hood").font(.title3.weight(.semibold))
            Text("Electrical details straight from the battery, for when you want the specifics.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    private func technicalStats(_ battery: BatterySnapshot) -> some View {
        HStack(spacing: 16) {
            DetailStat(label: "Voltage", term: "V",
                       value: battery.voltage.map { String(format: "%.2f V", $0) } ?? "—",
                       caption: "Battery pack voltage")
            DetailStat(label: "Current", term: "mA",
                       value: battery.amperage.map { "\($0 > 0 ? "+" : "")\($0) mA" } ?? "—",
                       caption: (battery.amperage ?? 0) < 0 ? "Flowing out (discharging)" : "Flowing in (charging)")
            DetailStat(label: "Capacity", term: "mAh",
                       value: battery.maxCapacity.map { "\($0.formatted()) mAh" } ?? "—",
                       caption: battery.designCapacity.map { "Design: \($0.formatted()) mAh" } ?? "")
            if let temperature = battery.temperature {
                DetailStat(label: "Temperature", term: "°C",
                           value: String(format: "%.1f °C", temperature),
                           caption: temperature > 40 ? "Warm: heat speeds up aging" : "Normal")
            } else {
                DetailStat(label: "Charger", term: "Adapter",
                           value: battery.adapterWatts.map { "\($0) W" } ?? (battery.isPluggedIn ? "Connected" : "None"),
                           caption: battery.adapterName ?? (battery.isPluggedIn ? "Power adapter" : "Running on battery"))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var powerHistory: some View {
        let samples = monitor.history(for: range).compactMap(\.batteryWatts)
        let average = samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
        return Card("Power draw on battery", systemImage: "bolt", tint: Theme.battery) {
            HistoryChart(
                points: monitor.points(\.batteryWatts, series: "Power", range: range),
                series: [.init(name: "Power", color: .orange)],
                range: range,
                reference: average.map { .init(label: "Average", value: $0) },
                format: { String(format: "%.0f W", $0) }
            )
            .frame(height: 160)
            Text("Recorded only while unplugged. Gaps are when you were on the charger.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } accessory: {
            HistoryRangePicker()
        }
    }
}
