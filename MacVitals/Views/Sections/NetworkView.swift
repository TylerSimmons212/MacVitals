import SwiftUI

/// Live network checks for the Network page. Runs only while the page is on screen:
/// Wi-Fi + per-app usage every 3s, router/internet response time every 10s.
@MainActor
@Observable
final class NetworkModel {
    struct AppTraffic: Identifiable, Equatable {
        let id: String
        let name: String
        let bundlePath: String?
        let kind: AppKind
        let isCurrentApp: Bool
        var download: Double
        var upload: Double
        var total: Double { download + upload }
    }

    private(set) var wifi: WiFiInfo?
    private(set) var config = NetworkConfig()
    private(set) var router: PingResult?
    private(set) var internet: PingResult?
    private(set) var apps: [AppTraffic] = []
    private(set) var speedTest: SpeedTestResult? = SpeedTestResult.loadLast()
    private(set) var isTestingSpeed = false

    @ObservationIgnored private var previous: [pid_t: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    @ObservationIgnored private var previousTime: Date?

    /// Public host used for the "internet" half of the Wi-Fi vs. internet check.
    static let internetProbeHost = "1.1.1.1"

    func run(monitor: SystemMonitor) async {
        var tick = 0
        while !Task.isCancelled {
            wifi = WiFiInfo.current()
            config = NetworkConfig.current()
            await updateApps(monitor: monitor)
            if tick % 3 == 0 { await updateLatency() }
            tick += 1
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func updateLatency() async {
        guard config.isOnline else {
            router = nil
            internet = PingResult(averageMs: nil, lossPercent: 100)
            return
        }
        let routerHost = config.router
        async let routerResult: PingResult? = routerHost == nil ? nil : PingResult.run(host: routerHost!)
        async let internetResult = PingResult.run(host: Self.internetProbeHost)
        router = await routerResult
        internet = await internetResult
    }

    private func updateApps(monitor: SystemMonitor) async {
        let entries = await NettopReader.read()
        let now = Date()
        defer {
            previous = Dictionary(entries.map { ($0.pid, ($0.bytesIn, $0.bytesOut)) }, uniquingKeysWith: { a, _ in a })
            previousTime = now
        }
        guard let previousTime else { return }
        let seconds = now.timeIntervalSince(previousTime)
        guard seconds > 0 else { return }

        // Map each process to the app it belongs to (same grouping as the rest of the app).
        var owner: [pid_t: AppUsage] = [:]
        for app in monitor.apps { for process in app.processes { owner[process.pid] = app } }

        var grouped: [String: AppTraffic] = [:]
        for entry in entries {
            guard let old = previous[entry.pid] else { continue }
            let down = entry.bytesIn >= old.bytesIn ? Double(entry.bytesIn - old.bytesIn) / seconds : 0
            let up = entry.bytesOut >= old.bytesOut ? Double(entry.bytesOut - old.bytesOut) / seconds : 0
            guard down + up > 0 else { continue }
            if let app = owner[entry.pid] {
                grouped[app.id, default: AppTraffic(id: app.id, name: app.name, bundlePath: app.bundlePath, kind: app.kind,
                                                    isCurrentApp: app.isCurrentApp, download: 0, upload: 0)].download += down
                grouped[app.id]?.upload += up
            } else {
                // Root-owned system services (push notifications, DNS, iCloud) we can't attribute further.
                grouped["system", default: AppTraffic(id: "system", name: "macOS services", bundlePath: nil, kind: .system,
                                                      isCurrentApp: false, download: 0, upload: 0)].download += down
                grouped["system"]?.upload += up
            }
        }
        apps = grouped.values.sorted { $0.total > $1.total }
    }

    func runSpeedTest() async {
        guard !isTestingSpeed else { return }
        isTestingSpeed = true
        defer { isTestingSpeed = false }
        if let result = await SpeedTestResult.run() {
            result.save()
            speedTest = result
        }
    }
}

/// Network page. For everyone: is my connection OK, and if not is it my Wi-Fi or my internet;
/// how fast is it; what's using it; how much data have I used. Under the hood: link details.
struct NetworkView: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage(SettingsKeys.historyRange) private var rangeRaw = HistoryRange.hour.rawValue
    @State private var model = NetworkModel()

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .hour }

    private var level: NetworkInsights.Level {
        NetworkInsights.level(config: model.config, wifi: model.wifi, router: model.router, internet: model.internet)
    }

    var body: some View {
        SectionScroll {
            verdict.entrance()
            stats.entrance(delay: 0.04)
            SpeedTestCard(model: model).entrance(delay: 0.08)
            HStack(alignment: .top, spacing: 16) {
                appsCard
                dataUsedCard
            }
            .fixedSize(horizontal: false, vertical: true)
            .entrance(delay: 0.12)
            history.entrance(delay: 0.16)

            underTheHoodHeader
            detailsCard
        }
        .task { await model.run(monitor: monitor) }
    }

    // MARK: Verdict

    private var verdict: some View {
        let level = level
        let tint = Theme.networkLevel(level)
        let latency = model.internet?.averageMs

        return HStack(spacing: 22) {
            ZStack {
                GaugeRing(fraction: level.quality / 100, color: tint, lineWidth: 12)
                if level == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 0) {
                        RollingText(latency.map { String(format: "%.0f", $0) } ?? "—", size: 30)
                        Text(latency == nil ? "no response" : "ms response")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                Text(level.title)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.interpolate)
                    .animation(.smooth, value: level)
                Text(level.sentence)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let wifi = model.wifi {
                        let signal = NetworkInsights.signal(rssi: wifi.rssi)
                        InfoChip(text: "Wi-Fi · \(signal.title) signal", icon: "wifi", tint: signal == .weak ? .orange : .secondary)
                    } else if model.config.isOnline {
                        InfoChip(text: "Wired connection", icon: "cable.connector")
                    }
                    if model.config.isVPN {
                        InfoChip(text: "VPN on", icon: "lock.shield")
                            .help("Traffic is going through a VPN, which can add delay.")
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
        let network = monitor.network
        return HStack(spacing: 16) {
            DetailStat(
                label: "Download", term: "In",
                value: Fmt.rate(network.downloadRate),
                caption: "\(Fmt.bytes(network.sessionReceived)) received since launch"
            )
            DetailStat(
                label: "Upload", term: "Out",
                value: Fmt.rate(network.uploadRate),
                caption: "\(Fmt.bytes(network.sessionSent)) sent since launch"
            )
            DetailStat(
                label: "Response time", term: "Ping",
                value: model.internet?.averageMs.map { String(format: "%.0f ms", $0) } ?? "—",
                tint: (model.internet?.averageMs ?? 0) > 120 ? .orange : nil,
                caption: routerCaption,
                help: "How long the internet takes to answer (to \(NetworkModel.internetProbeHost)), compared with your router. Lower is better; under 50 ms feels instant."
            )
            if let wifi = model.wifi {
                let signal = NetworkInsights.signal(rssi: wifi.rssi)
                DetailStat(
                    label: "Wi-Fi signal", term: "RSSI",
                    value: signal.title,
                    tint: signal == .weak ? .orange : (signal == .excellent ? .green : nil),
                    caption: "\(wifi.rssi) dBm\(wifi.bandName.map { " · \($0)" } ?? "")",
                    help: "Signal strength from your router. Closer to 0 dBm is stronger; below −75 dBm gets unreliable."
                )
            } else {
                DetailStat(label: "Connection", term: "Link", value: model.config.isOnline ? "Wired" : "Offline",
                           caption: model.config.primaryInterface ?? "No network")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var routerCaption: String {
        guard let router = model.router else { return "Checking your router…" }
        if let ms = router.averageMs { return String(format: "Router: %.0f ms", ms) }
        return "Router doesn't answer pings"
    }

    // MARK: Apps

    private var appsCard: some View {
        let ranked = Array(model.apps.prefix(8))
        let maxTotal = max(ranked.first?.total ?? 1, 1)
        return Card("What's using the internet", systemImage: "list.number", tint: Theme.network) {
            VStack(spacing: 10) {
                if ranked.isEmpty {
                    Text("Nothing is using the network much right now.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(ranked) { app in
                    HStack(spacing: 10) {
                        AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(app.name).lineLimit(1)
                                if app.isCurrentApp { ThisAppBadge() }
                                Spacer()
                                Label(Fmt.rate(app.download), systemImage: "arrow.down")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Label(Fmt.rate(app.upload), systemImage: "arrow.up")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .trailing)
                            }
                            MeterBar(fraction: app.total / maxTotal, tint: Theme.network, height: 4)
                        }
                    }
                }
            }
        }
        .fillingHeight()
    }

    // MARK: Data used

    private var dataUsedCard: some View {
        let calendar = Calendar.current
        let now = Date()
        let today = NetworkInsights.usage(monitor.history(for: .day), sampleLength: 60, since: calendar.startOfDay(for: now))
        let month = monitor.history(for: .month)
        let week = NetworkInsights.usage(month, sampleLength: 900, since: now.addingTimeInterval(-7 * 86_400))
        let thirty = NetworkInsights.usage(month, sampleLength: 900, since: now.addingTimeInterval(-30 * 86_400))

        return Card("Data used", systemImage: "chart.bar", tint: Theme.network) {
            VStack(spacing: 12) {
                usageRow("Today", today)
                usageRow("Last 7 days", week)
                usageRow("Last 30 days", thirty)
            }
            Text("Counted while Mac Vitals is running. Handy on a hotspot or a capped plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fillingHeight()
    }

    private func usageRow(_ label: String, _ usage: NetworkInsights.Usage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.callout.weight(.medium))
                Spacer()
                Text(Fmt.bytes(Int64(usage.total))).font(.callout.weight(.semibold)).monospacedDigit()
            }
            SegmentedBar(segments: [
                .init(label: "Down", value: max(usage.received, 0.001), color: Theme.network),
                .init(label: "Up", value: usage.sent, color: Theme.upload),
            ], height: 6)
            HStack(spacing: 10) {
                Label(Fmt.bytes(Int64(usage.received)), systemImage: "arrow.down").foregroundStyle(Theme.network)
                Label(Fmt.bytes(Int64(usage.sent)), systemImage: "arrow.up").foregroundStyle(Theme.upload)
            }
            .font(.caption)
            .monospacedDigit()
        }
    }

    // MARK: History

    private var history: some View {
        let samples = monitor.history(for: range)
        return Card("History", systemImage: "chart.xyaxis.line", tint: Theme.network) {
            HistoryChart(
                points: monitor.points(\.networkIn, series: "Download", range: range)
                    + monitor.points(\.networkOut, series: "Upload", range: range),
                series: [.init(name: "Download", color: Theme.network), .init(name: "Upload", color: Theme.upload)],
                range: range,
                format: { Fmt.rate($0) }
            )
            .frame(height: 190)
        } accessory: {
            HStack(spacing: 14) {
                if !samples.isEmpty {
                    summaryValue("Peak down", Fmt.rate(samples.map(\.networkIn).max() ?? 0))
                    summaryValue("Peak up", Fmt.rate(samples.map(\.networkOut).max() ?? 0))
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

    // MARK: Under the hood

    private var underTheHoodHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Under the hood").font(.title3.weight(.semibold))
            Text("Connection details, for when you want the technical specifics.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    private var detailsCard: some View {
        let wifi = model.wifi
        let config = model.config
        var rows: [(String, String)] = []
        if let wifi {
            rows.append(("Standard", wifi.standard))
            if let band = wifi.bandName { rows.append(("Band", band + (wifi.widthName.map { " · \($0) wide" } ?? ""))) }
            if let channel = wifi.channel { rows.append(("Channel", "\(channel)")) }
            rows.append(("Link rate", String(format: "%.0f Mbps", wifi.transmitRate)))
            rows.append(("Signal / noise", "\(wifi.rssi) dBm / \(wifi.noise) dBm"))
            rows.append(("Signal-to-noise", "\(wifi.signalToNoise) dB \(wifi.signalToNoise >= 25 ? "(clean)" : "(noisy)")"))
        }
        rows.append(("Interface", (config.primaryInterface ?? "—") + (config.isVPN ? " (VPN)" : "")))
        rows.append(("Local IP", config.localIPv4 ?? "—"))
        rows.append(("Router", config.router ?? "—"))
        rows.append(("DNS", config.dnsServers.prefix(2).joined(separator: ", ").ifEmpty("—")))
        if let router = model.router, let internet = model.internet {
            rows.append(("Packet loss", "Router \(Fmt.percent(router.lossPercent)) · Internet \(Fmt.percent(internet.lossPercent))"))
        }

        return Card("Connection details", systemImage: "antenna.radiowaves.left.and.right", tint: Theme.network) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1).monospacedDigit().textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.callout)
                }
            }
            Text("The Wi-Fi network name needs Location access in macOS, so Mac Vitals doesn't show it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Speed test

private struct SpeedTestCard: View {
    let model: NetworkModel
    @Environment(\.motionEnabled) private var motionEnabled

    var body: some View {
        Card("Speed test", systemImage: "speedometer", tint: Theme.network) {
            if model.isTestingSpeed {
                HStack(spacing: 14) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.network)
                        .symbolEffect(.variableColor.iterative, isActive: motionEnabled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Testing your connection…").font(.headline)
                        Text("Measuring download, upload and responsiveness. This takes about 20 seconds.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            } else if let result = model.speedTest {
                results(result)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How fast is your internet?").font(.headline)
                        Text("Runs Apple's built-in speed test (the same one as the networkQuality tool). Takes about 20 seconds and uses a few hundred MB of data.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    testButton("Test my speed", prominent: true)
                }
            }
        } accessory: {
            if let result = model.speedTest, !model.isTestingSpeed {
                HStack(spacing: 8) {
                    Text("Tested \(result.date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                    testButton("Test again", prominent: false)
                }
            }
        }
    }

    private func results(_ result: SpeedTestResult) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NetworkInsights.speedVerdict(result))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.network)
                Text("internet connection").foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            speedValue("Download", NetworkInsights.formatMbps(result.downloadMbps), icon: "arrow.down.circle.fill", tint: Theme.network)
            speedValue("Upload", NetworkInsights.formatMbps(result.uploadMbps), icon: "arrow.up.circle.fill", tint: Theme.upload)
            speedValue("Responsiveness", NetworkInsights.responsivenessLabel(rpm: result.responsivenessRPM),
                       icon: "bolt.horizontal.circle.fill", tint: .yellow,
                       caption: result.responsivenessRPM.map { String(format: "%.0f RPM", $0) })
                .help("How well the connection keeps up under load (round-trips per minute). High is great for calls and games.")
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(NetworkInsights.activities(for: result)) { activity in
                    Label(activity.name, systemImage: activity.supported ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(activity.supported ? .green : .secondary)
                        .font(.callout)
                }
            }
        }
    }

    private func speedValue(_ label: String, _ value: String, icon: String, tint: Color, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: icon).font(.caption).foregroundStyle(tint)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    private func testButton(_ title: String, prominent: Bool) -> some View {
        Group {
            if prominent {
                Button { Task { await model.runSpeedTest() } } label: { Label(title, systemImage: "speedometer") }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.network)
            } else {
                Button { Task { await model.runSpeedTest() } } label: { Text(title) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .pointerStyle(.link)
    }
}
