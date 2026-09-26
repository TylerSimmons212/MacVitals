import Foundation
import Observation
import SwiftUI

struct SystemSnapshot: Sendable {
    let date: Date
    let cpu: CPUSnapshot
    let memory: MemorySnapshot
    let disk: DiskSnapshot
    let network: NetworkSnapshot
    let battery: BatterySnapshot?
    let thermal: ThermalLevel
    let apps: [AppUsage]?
}

/// Whether the menu bar icon should call for attention. Info-level issues don't count,
/// so the badge keeps its meaning.
enum Attention: Equatable, Sendable {
    case none, warning, critical

    init(_ report: HealthReport) {
        let worst = report.issues.map(\.severity).max()
        switch worst {
        case .critical: self = .critical
        case .warning: self = .warning
        default: self = .none
        }
    }
}

/// Owns all samplers and runs them off the main thread.
actor SystemSampler {
    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let disk = DiskSampler()
    private let network = NetworkSampler()
    private let battery = BatterySampler()
    private let processes = ProcessSampler()

    /// Per-process sampling is by far the most expensive part, so it's skipped when no
    /// window that shows apps is on screen. `apps` is nil in that case.
    func sample(includeProcesses: Bool) -> SystemSnapshot {
        SystemSnapshot(
            date: Date(),
            cpu: cpu.sample(),
            memory: memory.sample(),
            disk: disk.sample(),
            network: network.sample(),
            battery: battery.sample(),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            apps: includeProcesses ? processes.sample() : nil
        )
    }
}

/// Main-actor store the UI observes. Samples on a timer and keeps rolling history.
@MainActor
@Observable
final class SystemMonitor {
    let info = SystemInfo.current()

    private(set) var cpu = CPUSnapshot.zero
    private(set) var memory = MemorySnapshot.zero
    private(set) var disk = DiskSnapshot.zero
    private(set) var network = NetworkSnapshot.zero
    private(set) var battery: BatterySnapshot?
    private(set) var thermal = ThermalLevel.nominal
    private(set) var apps: [AppUsage] = []
    private(set) var health = HealthReport.pending
    /// Bumped whenever new history is published. Views read it (via `history(...)`/`points(...)`)
    /// to re-render on new data without copying the whole history into observed state.
    private(set) var historyRevision = 0
    private(set) var lastUpdated: Date?
    /// Drives the menu bar icon badge. Only assigned when it changes, so the status item
    /// doesn't redraw on every sample.
    private(set) var attention = Attention.none
    /// Apps that look stuck busy or are leaking memory, keyed by app ID.
    private(set) var appFlags: [String: [AppInsights.Flag]] = [:]

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var viewers: Set<String> = []
    @ObservationIgnored private var wakeUp: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var pauseGeneration = 0
    /// Tiered history, always recorded (even while nothing is on screen) and persisted to disk.
    @ObservationIgnored private var historyStore = HistoryPersistence.load()
    @ObservationIgnored private var lastHistorySave = Date()
    @ObservationIgnored private var trends = AppTrendTracker()
    @ObservationIgnored private var backgroundTick = 0
    /// Latest sample not yet shown to views (held back while no window is visible).
    @ObservationIgnored private var unpublished: (snapshot: SystemSnapshot, report: HealthReport)?

    /// True while the dashboard or menu bar panel is on screen.
    var isBeingWatched: Bool { !viewers.isEmpty }

    /// Windows call this as they appear/disappear. When something becomes visible we sample
    /// immediately instead of waiting out the (longer) background interval.
    func setViewer(_ id: String, visible: Bool) {
        let wasWatched = isBeingWatched
        if visible { viewers.insert(id) } else { viewers.remove(id) }
        if isBeingWatched && !wasWatched {
            // Show the latest held-back data right away, then sample fresh (with processes).
            if let pending = unpublished { publish(pending.snapshot, report: pending.report) }
            wakeUp?.resume()
            wakeUp = nil
        }
    }

    var hasBattery: Bool { battery != nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let sampler = self?.sampler else { return }
            Responsiveness.shared.start { [weak self] in self?.isBeingWatched ?? false }
            // Prime the delta-based samplers, then publish quickly so the UI isn't empty.
            _ = await sampler.sample(includeProcesses: true)
            try? await Task.sleep(for: .milliseconds(800))
            while !Task.isCancelled {
                guard let self else { return }
                let watched = self.isBeingWatched
                // In the background, still sample processes every ~30s (a couple of ms each)
                // so stuck/leaking apps can be spotted over time.
                self.backgroundTick &+= 1
                let includeProcesses = watched || self.backgroundTick % 6 == 0
                let snapshot = await sampler.sample(includeProcesses: includeProcesses)
                self.apply(snapshot)
                await self.pause()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// User's interval while something is on screen; at least 5s in the background
    /// (only the menu bar label and health score need data then).
    private var refreshInterval: Double {
        let value = UserDefaults.standard.double(forKey: SettingsKeys.refreshInterval)
        let foreground = value > 0 ? value : 2
        return isBeingWatched ? foreground : max(5, foreground)
    }

    /// Sleeps for the refresh interval, or less if a window becomes visible meanwhile.
    private func pause() async {
        let interval = refreshInterval
        pauseGeneration += 1
        let generation = pauseGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wakeUp = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                // Ignore timers from earlier pauses that were cut short by a wake-up.
                guard let self, self.pauseGeneration == generation, let pending = self.wakeUp else { return }
                self.wakeUp = nil
                pending.resume()
            }
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        historyStore.append(HistorySample(
            date: snapshot.date,
            cpuUser: snapshot.cpu.user,
            cpuSystem: snapshot.cpu.system,
            memoryUsedPercent: snapshot.memory.usedPercent,
            networkIn: snapshot.network.downloadRate,
            networkOut: snapshot.network.uploadRate,
            diskRead: snapshot.disk.readRate,
            diskWrite: snapshot.disk.writeRate,
            batteryPercent: snapshot.battery?.percent,
            swapUsed: Double(snapshot.memory.swapUsed),
            diskFree: snapshot.disk.availableCapacity > 0 ? Double(snapshot.disk.availableCapacity) : nil,
            memoryTight: snapshot.memory.pressure == .normal ? 0 : 1,
            batteryWatts: snapshot.battery.flatMap { $0.isPluggedIn ? nil : $0.watts.map { max(0, $0) } }
        ))
        // Periodic save so a crash or force-quit loses at most a couple of minutes.
        if Date().timeIntervalSince(lastHistorySave) > 120 { saveHistory() }
        let report = HealthEvaluator.evaluate(HealthInputs(
            cpuAverage: historyStore.live.average(\.cpuTotal, over: 60),
            memory: snapshot.memory,
            disk: snapshot.disk,
            battery: snapshot.battery,
            thermal: snapshot.thermal,
            uptime: info.uptime,
            frozenApps: Responsiveness.shared.frozen
        ))

        if let apps = snapshot.apps { trends.record(apps, at: snapshot.date) }

        // Notifications keep working with every window closed (throttled inside to every 30 s).
        let trends = self.trends
        AlertCenter.shared.observe(report: report, flags: trends.flags(now: snapshot.date),
                                   apps: snapshot.apps, userIsLooking: isBeingWatched)

        // The menu bar badge is the only thing that must stay live in the background.
        let newAttention = Attention(report)
        if newAttention != attention { attention = newAttention }

        // Nobody looking → don't touch observed state. SwiftUI keeps re-rendering hidden and
        // occluded windows whenever observed data changes, which was most of our idle CPU.
        guard isBeingWatched else {
            unpublished = (snapshot, report)
            return
        }
        publish(snapshot, report: report)
    }

    private func publish(_ snapshot: SystemSnapshot, report: HealthReport) {
        unpublished = nil
        // No global withAnimation here: animating the whole tree every refresh re-runs layout
        // on every frame (measured 51% CPU vs 15%). Views animate locally via `.rollingNumber`
        // and value-scoped `.animation` on meters/rings instead.
        if let apps = snapshot.apps {
            self.apps = apps
            let flags = trends.flags(now: snapshot.date)
            if flags != appFlags { appFlags = flags }
        }
        historyRevision &+= 1
        lastUpdated = snapshot.date
        cpu = snapshot.cpu
        memory = snapshot.memory
        disk = snapshot.disk
        network = snapshot.network
        battery = snapshot.battery
        thermal = snapshot.thermal
        health = report
    }

    // MARK: History access (tracked via historyRevision)

    func history(for range: HistoryRange) -> [HistorySample] {
        _ = historyRevision
        return historyStore.samples(for: range)
    }

    func points(_ keyPath: KeyPath<HistorySample, Double>, series: String, range: HistoryRange) -> [ChartPoint] {
        _ = historyRevision
        return historyStore.points(keyPath, series: series, range: range)
    }

    func points(_ keyPath: KeyPath<HistorySample, Double?>, series: String, range: HistoryRange) -> [ChartPoint] {
        _ = historyRevision
        return historyStore.points(keyPath, series: series, range: range)
    }

    /// Average of a metric over the last `seconds` of live samples.
    func recentAverage(_ keyPath: KeyPath<HistorySample, Double>, over seconds: TimeInterval) -> Double {
        _ = historyRevision
        return historyStore.live.average(keyPath, over: seconds)
    }

    var historyStart: Date? {
        _ = historyRevision
        return historyStore.earliestDate
    }

    func saveHistory() {
        HistoryPersistence.save(historyStore)
        lastHistorySave = Date()
    }

    /// Process-level lookup used by the Dev Servers view.
    func process(pid: pid_t) -> ProcessUsage? {
        for app in apps {
            if let match = app.processes.first(where: { $0.pid == pid }) { return match }
        }
        return nil
    }
}
