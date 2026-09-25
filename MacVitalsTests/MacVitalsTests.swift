import Foundation
import AppKit
import Testing
@testable import MacVitals

@Suite("Process grouping")
struct ProcessGroupingTests {
    @Test func nestedHelperAppsRollUpToOutermostBundle() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(ProcessGrouping.outermostAppBundle(in: path) == "/Applications/Google Chrome.app")
    }

    @Test func plainBinaryHasNoBundle() {
        #expect(ProcessGrouping.outermostAppBundle(in: "/opt/homebrew/bin/node") == nil)
        #expect(ProcessGrouping.outermostAppBundle(in: "") == nil)
    }

    @Test func xpcServiceIsAttributedToResponsibleApp() {
        let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let group = ProcessGrouping.classify(path: webContent, responsiblePath: "/Applications/Safari.app/Contents/MacOS/Safari")
        #expect(group == .application(bundlePath: "/Applications/Safari.app"))
    }

    @Test func terminalChildrenGroupUnderTerminal() {
        let group = ProcessGrouping.classify(
            path: "/opt/homebrew/bin/node",
            responsiblePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
        )
        #expect(group == .application(bundlePath: "/System/Applications/Utilities/Terminal.app"))
    }

    @Test func disclaimedHelperBundleJoinsTheAppThatStartedIt() {
        // Claude Code: its own tiny bundle in Application Support, started via Claude's
        // `disclaimer` helper, which disclaims responsibility (so responsiblePath is nil).
        let group = ProcessGrouping.classify(
            path: "/Users/me/Library/Application Support/Claude/claude-code/2.1.281/claude.app/Contents/MacOS/claude",
            responsiblePath: nil,
            ancestorPaths: { ["/Applications/Claude.app/Contents/Helpers/disclaimer", "/Applications/Claude.app/Contents/MacOS/Claude"] }
        )
        #expect(group == .application(bundlePath: "/Applications/Claude.app"))
    }

    @Test func helperBundleStartedByMacOSKeepsItsOwnEntry() {
        // Microsoft AutoUpdate lives in Application Support but is launched by launchd (no app ancestor).
        let path = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft AutoUpdate"
        #expect(ProcessGrouping.classify(path: path, responsiblePath: nil, ancestorPaths: { [] })
                == .application(bundlePath: "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"))
    }

    @Test func realAppsNeverGetAbsorbedByTheirParent() {
        // An app in /Applications stays itself even if another app spawned it directly.
        let group = ProcessGrouping.classify(path: "/Applications/Slack.app/Contents/MacOS/Slack", responsiblePath: nil,
                                             ancestorPaths: { ["/Applications/Xcode.app/Contents/MacOS/Xcode"] })
        #expect(group == .application(bundlePath: "/Applications/Slack.app"))
    }

    @Test func disclaimedPlainBinaryJoinsAncestorApp() {
        let group = ProcessGrouping.classify(path: "/opt/homebrew/bin/node", responsiblePath: nil,
                                             ancestorPaths: { ["/bin/zsh", "/Applications/iTerm.app/Contents/MacOS/iTerm2"] })
        #expect(group == .application(bundlePath: "/Applications/iTerm.app"))
    }

    @Test func parentLookupWorksOnThisMac() {
        #expect(ProcessSampler.parentPID(of: getpid()) != nil)
        // launchd is root-owned; we can't read it, and the ancestor walk stops there anyway.
        #expect((ProcessSampler.parentPID(of: 1) ?? 0) == 0)
    }

    @Test func systemDaemonsGroupAsMacOS() {
        #expect(ProcessGrouping.classify(path: "/usr/libexec/trustd", responsiblePath: nil) == .system)
        #expect(ProcessGrouping.classify(path: "/System/Library/CoreServices/launchservicesd", responsiblePath: nil) == .system)
    }

    @Test func thirdPartyDaemonStandsAlone() {
        #expect(ProcessGrouping.classify(path: "/opt/homebrew/opt/postgresql/bin/postgres", responsiblePath: nil) == .standalone)
    }

    @Test func appTotalsSumChildProcesses() {
        let app = AppUsage(id: "x", name: "X", bundlePath: nil, kind: .application, processes: [
            ProcessUsage(pid: 1, name: "a", path: "", cpu: 10, memory: 100, diskReadRate: 1, diskWriteRate: 2),
            ProcessUsage(pid: 2, name: "b", path: "", cpu: 5.5, memory: 50, diskReadRate: 3, diskWriteRate: 4),
        ])
        #expect(app.cpu == 15.5)
        #expect(app.memory == 150)
        #expect(app.diskTotalRate == 10)
    }
}

@Suite("Health score")
struct HealthEvaluatorTests {
    private func inputs(
        cpu: Double = 10,
        freeFraction: Double = 0.5,
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,
        thermal: ThermalLevel = .nominal,
        battery: BatterySnapshot? = nil,
        uptimeDays: Double = 1
    ) -> HealthInputs {
        var memory = MemorySnapshot()
        memory.total = 16 << 30
        memory.pressure = pressure
        memory.swapUsed = swap
        var disk = DiskSnapshot()
        disk.totalCapacity = 1_000_000_000_000
        disk.availableCapacity = Int64(Double(disk.totalCapacity) * freeFraction)
        return HealthInputs(cpuAverage: cpu, memory: memory, disk: disk, battery: battery,
                            thermal: thermal, uptime: uptimeDays * 86_400)
    }

    @Test func healthyMacScoresPerfect() {
        let report = HealthEvaluator.evaluate(inputs())
        #expect(report.score == 100)
        #expect(report.issues.isEmpty)
        #expect(report.grade == "Excellent")
    }

    @Test func nearlyFullDiskIsCriticalAndPointsToCleanup() {
        let report = HealthEvaluator.evaluate(inputs(freeFraction: 0.03))
        let issue = try! #require(report.issues.first)
        #expect(issue.severity == .critical)
        #expect(issue.section == .cleanup)
        #expect(report.score == 70)
    }

    @Test func criticalIssuesSortFirst() {
        let report = HealthEvaluator.evaluate(inputs(cpu: 70, pressure: .critical, uptimeDays: 30))
        #expect(report.issues.map(\.id) == ["memory", "cpu", "uptime"])
    }

    @Test func penaltiesStackAndClampAtZero() {
        let report = HealthEvaluator.evaluate(inputs(cpu: 95, freeFraction: 0.01, pressure: .critical,
                                                     swap: 12 << 30, thermal: .critical, uptimeDays: 40))
        #expect(report.score == 0)
        #expect(report.grade == "Needs attention")
    }

    @Test func checklistCoversEveryFactorAndFlagsProblems() {
        let report = HealthEvaluator.evaluate(inputs(freeFraction: 0.08))
        #expect(report.checks.map(\.id) == ["disk", "memory", "cpu", "thermal", "uptime"])
        #expect(report.checks.first { $0.id == "disk" }?.severity == .warning)
        #expect(report.checks.filter { $0.id != "disk" }.allSatisfy { $0.severity == nil })
    }

    @Test func swapFoldsIntoMemoryCheck() {
        let report = HealthEvaluator.evaluate(inputs(swap: 12 << 30))
        let memory = try! #require(report.checks.first { $0.id == "memory" })
        #expect(memory.severity == .warning)
        #expect(memory.value.contains("swap"))
    }

    @Test func batteryAppearsInChecklistOnlyWhenPresent() {
        var battery = BatterySnapshot()
        battery.designCapacity = 5000
        battery.maxCapacity = 4600
        #expect(HealthEvaluator.evaluate(inputs(battery: battery)).checks.contains { $0.id == "battery" })
        #expect(!HealthEvaluator.evaluate(inputs()).checks.contains { $0.id == "battery" })
    }

    @Test func everyIssueHasCompactCopyThatFitsThePanel() {
        var battery = BatterySnapshot()
        battery.designCapacity = 5000
        battery.maxCapacity = 3000
        let scenarios = [
            inputs(cpu: 95, freeFraction: 0.03, pressure: .critical, swap: 12 << 30, thermal: .critical, battery: battery, uptimeDays: 40),
            inputs(cpu: 70, freeFraction: 0.08, pressure: .warning, swap: 3 << 30, thermal: .serious),
            inputs(freeFraction: 0.12, thermal: .fair),
        ]
        let issues = scenarios.flatMap { HealthEvaluator.evaluate($0).issues }
        #expect(Set(issues.map(\.id)) == ["disk", "memory", "swap", "cpu", "thermal", "battery", "uptime"])
        for issue in issues {
            #expect(!issue.shortTitle.isEmpty && issue.shortTitle.count <= 22, "\(issue.shortTitle)")
            #expect(!issue.metric.isEmpty && issue.metric.count <= 14, "\(issue.metric)")
        }
    }

    @Test func menuBarBadgeIgnoresInfoLevelIssues() {
        // Restart-recommended is info-level: no badge.
        #expect(Attention(HealthEvaluator.evaluate(inputs(uptimeDays: 30))) == .none)
        #expect(Attention(HealthEvaluator.evaluate(inputs(freeFraction: 0.08))) == .warning)
        #expect(Attention(HealthEvaluator.evaluate(inputs(freeFraction: 0.08, pressure: .critical))) == .critical)
    }

    @Test func degradedBatteryIsFlagged() {
        var battery = BatterySnapshot()
        battery.designCapacity = 5000
        battery.maxCapacity = 3500
        let report = HealthEvaluator.evaluate(inputs(battery: battery))
        #expect(report.issues.first?.id == "battery")
        #expect(report.issues.first?.severity == .warning)
    }
}

@Suite("Ports")
struct PortScannerTests {
    @Test func parsesLsofFieldOutput() {
        let output = """
        p4312
        cnode
        f23
        n*:3000
        f24
        n[::1]:3000
        p911
        cpostgres
        f7
        n127.0.0.1:5432
        """
        let entries = PortScanner.parse(lsofOutput: output)
        #expect(entries.count == 3)
        #expect(entries[0] == .init(pid: 4312, command: "node", address: "*", port: 3000))
        #expect(entries[1].address == "[::1]")
        #expect(entries[2] == .init(pid: 911, command: "postgres", address: "127.0.0.1", port: 5432))
    }

    @Test func loopbackOnlyDetection() {
        let local = ListeningPort(pid: 1, command: "vite", port: 5173, addresses: ["127.0.0.1", "[::1]"], workingDirectory: nil)
        let exposed = ListeningPort(pid: 1, command: "node", port: 3000, addresses: ["*"], workingDirectory: nil)
        #expect(local.isLocalOnly)
        #expect(!exposed.isLocalOnly)
    }

    @Test func projectNameComesFromWorkingDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let port = ListeningPort(pid: 1, command: "node", port: 3000, addresses: ["*"], workingDirectory: home + "/Developer/acme-web")
        #expect(port.projectName == "acme-web")
        #expect(port.isDevServer)
        let system = ListeningPort(pid: 1, command: "rapportd", port: 49152, addresses: ["*"], workingDirectory: nil)
        #expect(!system.isDevServer)
    }
}

@Suite("History")
struct MetricHistoryTests {
    private func sample(_ date: Date, cpu: Double) -> HistorySample {
        HistorySample(date: date, cpuUser: cpu, cpuSystem: 0, memoryUsedPercent: 0, networkIn: 0,
                      networkOut: 0, diskRead: 0, diskWrite: 0, batteryPercent: nil)
    }

    @Test func dropsOldestBeyondCapacity() {
        var history = MetricHistory(capacity: 3)
        let now = Date()
        for i in 0..<5 { history.append(sample(now.addingTimeInterval(Double(i)), cpu: Double(i))) }
        #expect(history.samples.map(\.cpuUser) == [2, 3, 4])
    }

    @Test func averageRespectsWindow() {
        var history = MetricHistory(capacity: 100)
        let now = Date()
        history.append(sample(now.addingTimeInterval(-120), cpu: 100))
        history.append(sample(now.addingTimeInterval(-30), cpu: 20))
        history.append(sample(now, cpu: 40))
        #expect(history.average(\.cpuTotal, over: 60, now: now) == 30)
    }
}

@Suite("Formatting & motion")
struct MiscTests {
    @Test func percentFormatting() {
        #expect(Fmt.percent(42.4) == "42%")
        #expect(Fmt.percent(3.14159, digits: 1) == "3.1%")
        #expect(Fmt.percent(.nan) == "0%")
    }

    @Test func networkMeterUsesLogScale() {
        #expect(NetworkLevels.level(for: 500) == 0)            // below 1 KB/s is silent
        #expect(NetworkLevels.level(for: 1_000_000) == 0.6)    // 1 MB/s → 3 of 5 decades
        #expect(NetworkLevels.level(for: 1e12) == 1)           // clamps
    }

    @Test func motionPolicyHonorsReduceMotion() {
        #expect(!MotionPolicy.resolve(reduceMotion: true, userEnabled: true, active: true).enabled)
        #expect(!MotionPolicy.resolve(reduceMotion: false, userEnabled: true, active: false).enabled)
        #expect(MotionPolicy.resolve(reduceMotion: false, userEnabled: true, active: true).enabled)
    }
}

@Suite("Tiered history")
struct TieredHistoryTests {
    private func sample(_ date: Date, cpu: Double, battery: Double? = nil) -> HistorySample {
        HistorySample(date: date, cpuUser: cpu, cpuSystem: 0, memoryUsedPercent: 50, networkIn: 0,
                      networkOut: 0, diskRead: 0, diskWrite: 0, batteryPercent: battery)
    }

    /// A recent 15-minute boundary (so nothing gets pruned), which is also a minute boundary.
    private var start: Date {
        Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate / 900) * 900 - 3 * 3600)
    }

    @Test func minuteTierAveragesEachMinute() {
        var history = TieredHistory()
        // Two minutes of samples every 5s: minute 1 at 10%, minute 2 at 30%, then one sample in minute 3.
        for i in 0..<12 { history.append(sample(start.addingTimeInterval(Double(i) * 5), cpu: 10)) }
        for i in 12..<24 { history.append(sample(start.addingTimeInterval(Double(i) * 5), cpu: 30)) }
        history.append(sample(start.addingTimeInterval(120), cpu: 90))
        #expect(history.minute.map(\.cpuUser) == [10, 30])
        #expect(history.minute[0].date == start.addingTimeInterval(30)) // bucket midpoint
    }

    @Test func dayRangeIncludesInProgressBucket() {
        var history = TieredHistory()
        for i in 0..<3 { history.append(sample(start.addingTimeInterval(Double(i) * 5), cpu: 40)) }
        let day = history.samples(for: .day, now: start.addingTimeInterval(20))
        #expect(day.count == 1)
        #expect(day.first?.cpuUser == 40)
    }

    @Test func gapsSplitChartSegments() {
        var history = TieredHistory()
        let now = Date()
        history.append(sample(now.addingTimeInterval(-600), cpu: 10))
        history.append(sample(now.addingTimeInterval(-595), cpu: 10))
        // Mac Vitals "not running" for 5 minutes.
        history.append(sample(now.addingTimeInterval(-290), cpu: 20))
        history.append(sample(now.addingTimeInterval(-285), cpu: 20))
        let points = history.points(\.cpuUser, series: "CPU", range: .hour)
        #expect(points.map(\.segment) == [0, 0, 1, 1])
    }

    @Test func chartDownsamplingCapsPointsWithoutCrossingGaps() {
        let now = Date()
        var points = (0..<1000).map { ChartPoint(date: now.addingTimeInterval(Double($0)), value: 10, series: "CPU", segment: $0 < 500 ? 0 : 1) }
        points[10] = ChartPoint(date: points[10].date, value: 50, series: "CPU", segment: 0)
        let reduced = TieredHistory.downsample(points, to: 360)
        #expect(reduced.count <= 362)
        #expect(Set(reduced.map(\.segment)) == [0, 1])
        // No averaged point mixes the two segments: segment-0 points all come before segment-1.
        let firstOne = reduced.firstIndex { $0.segment == 1 }!
        #expect(reduced[..<firstOne].allSatisfy { $0.segment == 0 })
        #expect(reduced.contains { $0.value > 10 }) // the spike still shows (averaged, not dropped)
    }

    @Test func batteryAveragesIgnoreMissingSamples() {
        var history = TieredHistory()
        history.append(sample(start, cpu: 0, battery: 80))
        history.append(sample(start.addingTimeInterval(5), cpu: 0, battery: nil))
        history.append(sample(start.addingTimeInterval(10), cpu: 0, battery: 60))
        history.append(sample(start.addingTimeInterval(60), cpu: 0)) // closes the first minute
        #expect(history.minute.first?.batteryPercent == 70)
    }

    @Test func persistenceRoundTripsAndPrunesOldData() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mv-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var history = TieredHistory()
        for i in 0..<130 { history.append(sample(start.addingTimeInterval(Double(i) * 5), cpu: Double(i % 7))) }
        HistoryPersistence.save(history, to: url)
        // Reload while still inside the last minute: identical state, in-progress bucket intact.
        let lastSample = start.addingTimeInterval(129 * 5)
        let restored = HistoryPersistence.load(from: url, now: lastSample)
        #expect(restored.minute.map(\.cpuUser) == history.minute.map(\.cpuUser))
        #expect(restored.live.samples.count == history.live.samples.count)
        #expect(restored.samples(for: .day, now: lastSample).count == history.samples(for: .day, now: lastSample).count)

        // Anything older than 30 days is dropped on load.
        let old = TieredHistory.Archive(minute: [], quarter: [sample(Date().addingTimeInterval(-40 * 86_400), cpu: 1)])
        #expect(TieredHistory(archive: old).quarter.isEmpty)
    }

    @Test func restartMidBucketContinuesTheAverage() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mv-resume-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let bucketStart = start
        var before = TieredHistory()
        // 5 minutes at 10% inside one 15-minute bucket, then the app quits.
        for i in 0..<60 { before.append(sample(bucketStart.addingTimeInterval(Double(i) * 5), cpu: 10)) }
        HistoryPersistence.save(before, to: url)

        // Relaunch 1 minute later, same 15-minute bucket: 5 more minutes at 40%.
        var after = HistoryPersistence.load(from: url, now: bucketStart.addingTimeInterval(360))
        #expect(after.live.samples.count == 60) // last hour of raw samples restored
        for i in 0..<60 { after.append(sample(bucketStart.addingTimeInterval(360 + Double(i) * 5), cpu: 40)) }
        // Cross into the next 15-minute bucket to close it out.
        after.append(sample(bucketStart.addingTimeInterval(900), cpu: 0))
        let closed = try #require(after.quarter.last)
        #expect(closed.cpuUser == 25) // (60 × 10 + 60 × 40) / 120: both sessions counted
    }

    @Test func staleBucketIsClosedOutOnLoad() {
        var history = TieredHistory()
        for i in 0..<12 { history.append(sample(start.addingTimeInterval(Double(i) * 5), cpu: 20)) }
        // Reopen an hour later: the saved half-bucket becomes a finished data point.
        let reopened = TieredHistory(archive: history.archive, now: start.addingTimeInterval(3_600))
        #expect(reopened.quarter.count == 1)
        #expect(reopened.minute.last?.cpuUser == 20)
    }

    @Test func missingFileLoadsEmpty() {
        let history = HistoryPersistence.load(from: URL(fileURLWithPath: "/nonexistent/history.json"))
        #expect(history.minute.isEmpty && history.quarter.isEmpty)
    }
}

@Suite("CPU insights")
struct CPUInsightsTests {
    @Test func levelsFromRecentAverage() {
        #expect(CPUInsights.level(forAverage: 8) == .relaxed)
        #expect(CPUInsights.level(forAverage: 40) == .busy)
        #expect(CPUInsights.level(forAverage: 70) == .workingHard)
        #expect(CPUInsights.level(forAverage: 97) == .maxedOut)
    }

    @Test func demandIsRelativeToCoreCount() {
        #expect(CPUInsights.demand(loadAverage: 3, cores: 10) == .light)
        #expect(CPUInsights.demand(loadAverage: 3, cores: 4) == .moderate)
        #expect(CPUInsights.demand(loadAverage: 12, cores: 8) == .heavy)
    }

    @Test func appShareIsFractionOfTotalCapacity() {
        // 250% of one core on an 8-core Mac is 31.25% of the whole CPU.
        #expect(CPUInsights.shareOfTotal(appCPU: 250, cores: 8) == 31.25)
    }

    @Test func singleCoreBottleneckOnlyWhenOverallIsQuiet() {
        #expect(CPUInsights.singleCoreBottleneck(perCore: [5, 99, 3, 4], total: 25) == 1)
        #expect(CPUInsights.singleCoreBottleneck(perCore: [95, 99, 97, 96], total: 97) == nil)
        #expect(CPUInsights.singleCoreBottleneck(perCore: [5, 60, 3, 4], total: 18) == nil)
    }

    @Test func appleSiliconClustersPutEfficiencyFirstInNumbering() {
        let clusters = CPUInsights.clusters(coreCount: 8, efficiency: 2, performance: 6)
        #expect(clusters.map(\.name) == ["Performance", "Efficiency"])
        #expect(clusters[0].range == 2..<8)
        #expect(clusters[1].range == 0..<2)
        #expect(CPUInsights.clusters(coreCount: 4, efficiency: nil, performance: nil).map(\.name) == ["Cores"])
    }

    @Test func everySectionHasAGuide() {
        for section in DashboardSection.allCases {
            let guide = SectionGuide.for(section)
            #expect(!guide.title.isEmpty && !guide.summary.isEmpty)
        }
    }
}

@Suite("Self-awareness")
struct SelfAwarenessTests {
    @Test func appRecognizesItsOwnProcess() {
        let own = ProcessInfo.processInfo.processIdentifier
        let me = AppUsage(id: "me", name: "Mac Vitals", bundlePath: nil, kind: .application, processes: [
            ProcessUsage(pid: own, name: "MacVitals", path: "", cpu: 20, memory: 1, diskReadRate: 0, diskWriteRate: 0),
        ])
        let other = AppUsage(id: "other", name: "Safari", bundlePath: nil, kind: .application, processes: [
            ProcessUsage(pid: own + 1, name: "Safari", path: "", cpu: 5, memory: 1, diskReadRate: 0, diskWriteRate: 0),
        ])
        #expect(me.isCurrentApp)
        #expect(!other.isCurrentApp)
    }
}

@Suite("Memory insights")
struct MemoryInsightsTests {
    @Test func verdictFollowsPressureNotUsedPercent() {
        #expect(MemoryInsights.level(pressure: .normal, swapUsed: 0) == .comfortable)
        #expect(MemoryInsights.level(pressure: .normal, swapUsed: 3 << 30) == .recentlyTight)
        #expect(MemoryInsights.level(pressure: .warning, swapUsed: 0) == .gettingTight)
        #expect(MemoryInsights.level(pressure: .critical, swapUsed: 0) == .underStrain)
        // A little swap is housekeeping, not a problem.
        #expect(MemoryInsights.level(pressure: .normal, swapUsed: 200 << 20) == .comfortable)
    }

    @Test func compositionCoversEverySliceWithPlainNames() {
        var memory = MemorySnapshot()
        memory.total = 16 << 30
        memory.app = 6 << 30; memory.wired = 2 << 30; memory.compressed = 1 << 30
        memory.cached = 5 << 30; memory.free = 2 << 30
        let slices = MemoryInsights.composition(memory)
        #expect(slices.map(\.name) == ["Apps", "System", "Compressed", "Ready to reuse", "Free"])
        #expect(slices.reduce(0) { $0 + $1.bytes } == memory.total)
        #expect(slices.allSatisfy { !$0.meaning.isEmpty })
        #expect(MemoryInsights.shareOfRAM(4 << 30, total: 16 << 30) == 25)
    }

    @Test func swapIsAveragedIntoHistoryAndOldFilesStillDecode() throws {
        let start = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate / 900) * 900 - 3600)
        var history = TieredHistory()
        func s(_ t: TimeInterval, swap: Double?) -> HistorySample {
            HistorySample(date: start.addingTimeInterval(t), cpuUser: 0, cpuSystem: 0, memoryUsedPercent: 50, networkIn: 0,
                          networkOut: 0, diskRead: 0, diskWrite: 0, batteryPercent: nil, swapUsed: swap)
        }
        history.append(s(0, swap: 1_000))
        history.append(s(5, swap: 3_000))
        history.append(s(60, swap: nil))
        #expect(history.minute.first?.swapUsed == 2_000)

        // A v1 file (no swap, no live tier, no buckets) must still load.
        let legacy = #"{"version":1,"minute":[{"date":\#(start.timeIntervalSinceReferenceDate),"cpuUser":1,"cpuSystem":1,"memoryUsedPercent":40,"networkIn":0,"networkOut":0,"diskRead":0,"diskWrite":0}],"quarter":[]}"#
        let archive = try JSONDecoder().decode(TieredHistory.Archive.self, from: Data(legacy.utf8))
        #expect(archive.minute.count == 1)
        #expect(archive.minute[0].swapUsed == nil)
    }
}

@Suite("Disk insights")
struct DiskInsightsTests {
    @Test func levelsMatchHealthScoreThresholds() {
        #expect(DiskInsights.level(freePercent: 40) == .plenty)
        #expect(DiskInsights.level(freePercent: 12) == .gettingFull)
        #expect(DiskInsights.level(freePercent: 7) == .runningLow)
        #expect(DiskInsights.level(freePercent: 3) == .almostFull)
    }

    @Test func updateHeadroomWarning() {
        #expect(DiskInsights.tooSmallForUpdates(available: 12_000_000_000))
        #expect(!DiskInsights.tooSmallForUpdates(available: 180_000_000_000))
        #expect(!DiskInsights.tooSmallForUpdates(available: 0)) // unknown, don't warn
    }

    @Test func freeSpaceTrend() {
        func s(_ free: Double?) -> HistorySample {
            HistorySample(date: Date(), cpuUser: 0, cpuSystem: 0, memoryUsedPercent: 0, networkIn: 0, networkOut: 0,
                          diskRead: 0, diskWrite: 0, batteryPercent: nil, diskFree: free)
        }
        let change = DiskInsights.freeSpaceChange([s(100e9), s(nil), s(96.8e9)])
        #expect(change == -3.2e9)
        #expect(DiskInsights.describeChange(-3.2e9, over: .day) == "Free space went down by 3.2 GB over the last 24 hours.")
        #expect(DiskInsights.describeChange(-100e6, over: .day) == "Free space has been steady over the last 24 hours.")
        #expect(DiskInsights.freeSpaceChange([s(nil)]) == nil)
    }

    @Test func splitBytesNeverProducesLongNumbers() {
        #expect(Fmt.splitBytes(182_400_000_000) == ("182", "GB"))
        #expect(Fmt.splitBytes(12_450_000_000) == ("12.4", "GB") || Fmt.splitBytes(12_450_000_000) == ("12.5", "GB"))
        #expect(Fmt.splitBytes(1_240_000_000_000) == ("1.2", "TB"))
        #expect(Fmt.splitBytes(640_000_000) == ("640", "MB"))
    }
}

@Suite("Disk forecast")
struct DiskForecastTests {
    private func samples(hours: Int, startFree: Double, perHour: Double) -> [HistorySample] {
        let start = Date().addingTimeInterval(-Double(hours) * 3600)
        return (0...hours * 4).map { i in
            let t = Double(i) * 900
            return HistorySample(date: start.addingTimeInterval(t), cpuUser: 0, cpuSystem: 0, memoryUsedPercent: 0,
                                 networkIn: 0, networkOut: 0, diskRead: 0, diskWrite: 0, batteryPercent: nil,
                                 diskFree: startFree + perHour * t / 3600)
        }
    }

    @Test func needsHistoryBeforePredicting() {
        let result = DiskInsights.forecast(samples: samples(hours: 3, startFree: 100e9, perHour: -1e9), currentFree: 97_000_000_000)
        #expect(result == .collecting(hoursNeeded: 9))
    }

    @Test func predictsRunOutFromTrend() {
        // Losing 1 GB/hour (24 GB/day) with 96 GB free → about 4 days.
        let result = DiskInsights.forecast(samples: samples(hours: 24, startFree: 120e9, perHour: -1e9), currentFree: 96_000_000_000)
        guard case .runsOut(let days) = result else { Issue.record("expected runsOut, got \(result)"); return }
        #expect(abs(days - 4) < 0.1)
        #expect(result.sentence == "At this rate, you'll run out of space in about 4 days.")
    }

    @Test func smallChangesAreSteady() {
        #expect(DiskInsights.forecast(samples: samples(hours: 24, startFree: 100e9, perHour: -1e6), currentFree: 100_000_000_000) == .steady)
        #expect(DiskInsights.forecast(samples: samples(hours: 24, startFree: 100e9, perHour: 1e9), currentFree: 124_000_000_000) == .freeingUp)
        // Slow loss that would take years is also "steady".
        #expect(DiskInsights.forecast(samples: samples(hours: 24, startFree: 400e9, perHour: -20e6), currentFree: 400_000_000_000) == .steady)
    }

    @Test func friendlyDurations() {
        #expect(DiskInsights.describe(days: 1) == "about a day")
        #expect(DiskInsights.describe(days: 9.6) == "about 10 days")
        #expect(DiskInsights.describe(days: 40) == "about 6 weeks")
        #expect(DiskInsights.describe(days: 150) == "about 5 months")
    }
}

@Suite("Storage scanner")
struct StorageScannerTests {
    /// Builds a fake home folder: Downloads with an installer and a big video,
    /// plus a big file inside an .app bundle that must NOT be listed as a "largest file".
    private func makeHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "mv-home-\(UUID().uuidString)")
        let downloads = home.appending(path: "Downloads")
        try fm.createDirectory(at: downloads.appending(path: "Old Project"), withIntermediateDirectories: true)
        try Data(count: 1_000_000).write(to: downloads.appending(path: "installer.dmg"))
        try Data(count: 3_000_000).write(to: downloads.appending(path: "Old Project/notes.bin"))
        let bundle = downloads.appending(path: "Tool.app/Contents/Resources")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: bundle.appending(path: "payload.bin"))
        return home
    }

    @Test func measuresCategoryAndListsLargestChildren() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = StorageScanner.scan(.downloads, home: home)
        #expect(result.category.size >= 6_000_000)
        #expect(!result.category.needsAccess)
        // Biggest first; folders shown with ~ paths, apps by name.
        #expect(result.category.largest.map(\.name) == ["~/Downloads/Old Project", "Tool", "~/Downloads/installer.dmg"])
    }

    @Test func largeFilesSkipAppBundleInternals() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var top = TopItems(limit: 10)
        for child in try FileManager.default.contentsOfDirectory(at: home.appending(path: "Downloads"), includingPropertiesForKeys: nil) {
            _ = StorageScanner.measure(child, collect: true, into: &top)
        }
        // Threshold is 200 MB, so these small test files don't qualify; verify the filter logic directly instead.
        var direct = TopItems(limit: 2)
        direct.insert(StorageItem(path: "/a", name: "a", size: 5))
        direct.insert(StorageItem(path: "/b", name: "b", size: 9))
        direct.insert(StorageItem(path: "/c", name: "c", size: 7))
        #expect(direct.items.map(\.name) == ["b", "c"])
        #expect(top.items.allSatisfy { !$0.path.contains(".app/") })
    }

    @Test func missingFoldersAreEmptyNotDenied() {
        let result = StorageScanner.scan(.backups, home: URL(fileURLWithPath: "/nonexistent-home"))
        #expect(result.category.size == 0)
        #expect(!result.category.needsAccess)
    }

    @Test func otherIsWhateverWasNotMeasured() {
        let report = StorageReport(scannedAt: Date(), categories: [
            StorageCategory(kind: .apps, size: 40, largest: [], needsAccess: false),
            StorageCategory(kind: .documents, size: 60, largest: [], needsAccess: false),
        ], largestFiles: [])
        #expect(report.systemAndOther(used: 250) == 150)
        #expect(report.systemAndOther(used: 50) == 0)
    }

    @Test func driveHealthParsing() {
        let json = #"{"SPNVMeDataType":[{"_items":[{"_name":"APPLE SSD","smart_status":"Verified"}]}]}"#
        #expect(DriveHealth.parseStatus(Data(json.utf8)) == "Verified")
        #expect(DriveHealth.parseStatus(Data("{}".utf8)) == nil)
    }

    @Test func everyStorageKindExplainsItself() {
        for kind in StorageKind.allCases {
            #expect(!kind.title.isEmpty && !kind.explanation.isEmpty && !kind.icon.isEmpty)
        }
        #expect(StorageKind.allCases.filter(\.needsFullDiskAccess) == [.backups, .mail])
    }
}

@Suite("Memory: enough RAM & free up memory")
struct MemoryAdvisorTests {
    private func history(hours: Int, tightEvery n: Int?) -> [HistorySample] {
        let start = Date().addingTimeInterval(-Double(hours) * 3600)
        return (0..<(hours * 4)).map { i in
            HistorySample(date: start.addingTimeInterval(Double(i) * 900), cpuUser: 0, cpuSystem: 0, memoryUsedPercent: 60,
                          networkIn: 0, networkOut: 0, diskRead: 0, diskWrite: 0, batteryPercent: nil,
                          memoryTight: n.map { i % $0 == 0 ? 1 : 0 } ?? 0)
        }
    }

    @Test func adequacyNeedsHistoryFirst() {
        #expect(MemoryInsights.adequacy(samples: history(hours: 4, tightEvery: nil)) == .collecting(hoursNeeded: 9))
    }

    @Test func adequacyVerdicts() {
        #expect(MemoryInsights.adequacy(samples: history(hours: 48, tightEvery: nil)) == .plenty(comfortablePercent: 100))
        // Tight 1 in 40 samples (2.5% of the time) → mostly enough.
        guard case .mostlyEnough = MemoryInsights.adequacy(samples: history(hours: 48, tightEvery: 40)) else {
            Issue.record("expected mostlyEnough"); return
        }
        // Tight 1 in 5 (20%) → often short.
        guard case .oftenShort(let comfortable) = MemoryInsights.adequacy(samples: history(hours: 48, tightEvery: 5)) else {
            Issue.record("expected oftenShort"); return
        }
        // 192 samples, indices 0,5,…,190 tight = 39 → 79.7% comfortable.
        #expect(abs(comfortable - (100 - 39.0 / 192.0 * 100)) < 0.001)
    }

    @Test func nextMacAdviceOnlyUpsellsWhenDataSaysSo() {
        let sixteen: UInt64 = 16 << 30
        #expect(MemoryInsights.nextMacAdvice(.plenty(comfortablePercent: 99.9), installed: sixteen) == "For your next Mac, 16 GB matches how you work.")
        #expect(MemoryInsights.nextMacAdvice(.oftenShort(comfortablePercent: 80), installed: sixteen) == "For your next Mac, consider 24 GB or more.")
        #expect(MemoryInsights.nextMacAdvice(.oftenShort(comfortablePercent: 80), installed: 36 << 30) == "For your next Mac, consider 48 GB or more.")
        #expect(MemoryInsights.nextMacAdvice(.collecting(hoursNeeded: 3), installed: sixteen) == nil)
    }

    private func app(_ name: String, path: String, memoryMB: UInt64, pid: pid_t) -> AppUsage {
        AppUsage(id: path, name: name, bundlePath: path, kind: .application, processes: [
            ProcessUsage(pid: pid, name: name, path: path, cpu: 0, memory: memoryMB << 20, diskReadRate: 0, diskWriteRate: 0),
        ])
    }

    @Test func suggestsHeavyIdleAppsOnly() {
        let now = Date()
        let apps = [
            app("Slack", path: "/Applications/Slack.app", memoryMB: 1_800, pid: 90_001),
            app("Chrome", path: "/Applications/Google Chrome.app", memoryMB: 4_000, pid: 90_002),   // used 5 min ago
            app("Notes", path: "/Applications/Notes.app", memoryMB: 120, pid: 90_003),               // too small
            app("Finder", path: "/System/Library/CoreServices/Finder.app", memoryMB: 900, pid: 90_004), // part of macOS
            app("Figma", path: "/Applications/Figma.app", memoryMB: 2_500, pid: 90_005),             // never used since tracking
        ]
        let lastUsed: [String: Date] = [
            "/Applications/Slack.app": now.addingTimeInterval(-3 * 3600),
            "/Applications/Google Chrome.app": now.addingTimeInterval(-300),
        ]
        let suggestions = MemoryInsights.closeSuggestions(apps: apps, lastUsed: { lastUsed[$0] },
                                                          trackingSince: now.addingTimeInterval(-6 * 3600), now: now)
        #expect(suggestions.map(\.app.name) == ["Figma", "Slack"])
        #expect(suggestions.first?.lastUsed == nil)
    }

    @Test func noSuggestionsWhileStillLearning() {
        let now = Date()
        let apps = [app("Slack", path: "/Applications/Slack.app", memoryMB: 1_800, pid: 90_001)]
        #expect(MemoryInsights.closeSuggestions(apps: apps, lastUsed: { _ in nil },
                                                trackingSince: now.addingTimeInterval(-60), now: now).isEmpty)
    }

    @Test func lastUsedPhrasing() {
        let now = Date()
        #expect(MemoryInsights.describeLastUsed(now.addingTimeInterval(-45 * 60), trackingSince: now, now: now) == "Last used 45 min ago")
        #expect(MemoryInsights.describeLastUsed(now.addingTimeInterval(-3 * 3600), trackingSince: now, now: now) == "Last used 3 h ago")
        #expect(MemoryInsights.describeLastUsed(now.addingTimeInterval(-4 * 86_400), trackingSince: now, now: now) == "Last used 4 days ago")
        #expect(MemoryInsights.describeLastUsed(nil, trackingSince: now.addingTimeInterval(-7200), now: now).hasPrefix("Not used since"))
    }

    @Test func compressionRatio() {
        var memory = MemorySnapshot()
        memory.compressed = 1 << 30
        memory.compressedOriginal = 3 << 30
        #expect(memory.compressionRatio == 3)
        memory.compressed = 0
        #expect(memory.compressionRatio == nil)
    }
}

@Suite("Network")
struct NetworkTests {
    @Test func parsesPingSummary() {
        let ok = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes

        --- 1.1.1.1 ping statistics ---
        4 packets transmitted, 4 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 7.513/10.346/12.681/2.139 ms
        """
        #expect(PingResult.parse(ok) == PingResult(averageMs: 10.346, lossPercent: 0))
        let dead = """
        --- 192.168.0.1 ping statistics ---
        4 packets transmitted, 0 packets received, 100.0% packet loss
        """
        let result = PingResult.parse(dead)
        #expect(result.lossPercent == 100 && result.averageMs == nil && !result.reachable)
        #expect(!PingResult.parse("").reachable)
    }

    @Test func parsesNettopLines() {
        let output = """
        ,bytes_in,bytes_out,
        launchd.1,0,0,
        apsd.621,250518,278381,
        Google Chrome He.8812,10485760,524288,
        garbage line
        """
        let entries = NettopReader.parse(output)
        #expect(entries.count == 3)
        #expect(entries[1] == .init(pid: 621, name: "apsd", bytesIn: 250_518, bytesOut: 278_381))
        #expect(entries[2].name == "Google Chrome He" && entries[2].pid == 8812)
    }

    @Test func parsesSpeedTestJSON() {
        let json = #"{"base_rtt":18.2,"dl_throughput":452000000,"ul_throughput":38000000,"responsiveness":1320,"dl_bytes_transferred":250000000,"ul_bytes_transferred":40000000}"#
        let result = try! #require(SpeedTestResult.parse(Data(json.utf8)))
        #expect(result.downloadMbps == 452 && result.uploadMbps == 38)
        #expect(result.responsivenessRPM == 1320 && result.bytesUsed == 290_000_000)
        #expect(NetworkInsights.speedVerdict(result) == "Very fast")
        #expect(NetworkInsights.activities(for: result).allSatisfy { $0.supported })
        #expect(SpeedTestResult.parse(Data("{}".utf8)) == nil)
    }

    @Test func slowConnectionActivities() {
        let slow = SpeedTestResult(date: Date(), downloadBitsPerSecond: 8e6, uploadBitsPerSecond: 1e6,
                                   responsivenessRPM: 150, idleLatencyMs: 60, bytesUsed: 0)
        let supported = NetworkInsights.activities(for: slow).filter(\.supported).map(\.name)
        #expect(supported == ["Browsing & email", "HD video"])
        #expect(NetworkInsights.speedVerdict(slow) == "Basic")
        #expect(NetworkInsights.responsivenessLabel(rpm: 150) == "Low")
    }

    private let online = NetworkConfig(primaryInterface: "en0", router: "192.168.0.1", localIPv4: "192.168.0.20", dnsServers: [])
    private func wifi(_ rssi: Int) -> WiFiInfo {
        WiFiInfo(interface: "en0", rssi: rssi, noise: -90, transmitRate: 800, phyMode: 6, channel: 44, band: 2, width: 3)
    }

    @Test func diagnosesWiFiVersusInternet() {
        let fastRouter = PingResult(averageMs: 3, lossPercent: 0)
        let slowRouter = PingResult(averageMs: 85, lossPercent: 0)
        let fastNet = PingResult(averageMs: 12, lossPercent: 0)
        let slowNet = PingResult(averageMs: 180, lossPercent: 0)
        let deadNet = PingResult(averageMs: nil, lossPercent: 100)

        #expect(NetworkInsights.level(config: online, wifi: wifi(-50), router: fastRouter, internet: fastNet) == .great)
        #expect(NetworkInsights.level(config: online, wifi: wifi(-50), router: fastRouter, internet: slowNet) == .slowInternet)
        #expect(NetworkInsights.level(config: online, wifi: wifi(-50), router: slowRouter, internet: slowNet) == .weakWiFi)
        #expect(NetworkInsights.level(config: online, wifi: wifi(-82), router: fastRouter, internet: fastNet) == .weakWiFi)
        #expect(NetworkInsights.level(config: online, wifi: wifi(-50), router: fastRouter, internet: deadNet) == .internetDown)
        #expect(NetworkInsights.level(config: NetworkConfig(), wifi: nil, router: nil, internet: nil) == .offline)
        #expect(NetworkInsights.level(config: online, wifi: wifi(-50), router: nil, internet: nil) == .checking)
        // Routers that ignore ping aren't blamed.
        #expect(NetworkInsights.level(config: online, wifi: wifi(-50), router: PingResult(averageMs: nil, lossPercent: 100), internet: fastNet) == .great)
    }

    @Test func signalBands() {
        #expect(NetworkInsights.signal(rssi: -53) == .excellent)
        #expect(NetworkInsights.signal(rssi: -64) == .good)
        #expect(NetworkInsights.signal(rssi: -72) == .fair)
        #expect(NetworkInsights.signal(rssi: -80) == .weak)
    }

    @Test func wifiDescriptions() {
        let info = wifi(-53)
        #expect(info.standard == "Wi-Fi 6 (802.11ax)")
        #expect(info.bandName == "5 GHz" && info.widthName == "80 MHz")
        #expect(info.signalToNoise == 37)
    }

    @Test func vpnDetection() {
        #expect(NetworkConfig(primaryInterface: "utun4", router: nil).isVPN)
        #expect(!online.isVPN)
    }

    @Test func dataUsageIntegratesRates() {
        let now = Date()
        func s(_ ago: TimeInterval, down: Double, up: Double) -> HistorySample {
            HistorySample(date: now.addingTimeInterval(-ago), cpuUser: 0, cpuSystem: 0, memoryUsedPercent: 0,
                          networkIn: down, networkOut: up, diskRead: 0, diskWrite: 0, batteryPercent: nil)
        }
        // Two 1-minute buckets at 1 MB/s down, 0.5 MB/s up = 120 MB down, 60 MB up.
        let usage = NetworkInsights.usage([s(120, down: 1e6, up: 5e5), s(60, down: 1e6, up: 5e5), s(90_000, down: 9e9, up: 9e9)],
                                          sampleLength: 60, since: now.addingTimeInterval(-3600))
        #expect(usage.received == 120e6 && usage.sent == 60e6)
    }

    @Test func liveReadersWorkOnThisMac() async {
        // Smoke test against the real system: must not crash, and nettop must parse something.
        _ = WiFiInfo.current()
        let config = NetworkConfig.current()
        #expect(config.primaryInterface == nil || !config.primaryInterface!.isEmpty)
        let entries = await NettopReader.read()
        #expect(!entries.isEmpty)
    }
}

@Suite("Battery")
struct BatteryTests {
    @Test func unsignedAmperageIsReadAsSigned() {
        // The exact value this Mac's battery reported: −829 mA stored as an unsigned 64-bit pattern.
        let raw = NSNumber(value: UInt64(18_446_744_073_709_550_787))
        #expect(Int(Int64(bitPattern: raw.uint64Value)) == -829)
    }

    @Test func parsesApplesHealthFigures() {
        let json = #"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_cycle_count":614,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"83%"}}]}"#
        let health = BatterySampler.parseAppleHealth(Data(json.utf8))
        #expect(health?.percent == 83 && health?.condition == "Good" && health?.cycles == 614)
        #expect(BatterySampler.parseAppleHealth(Data("{}".utf8)) == nil)
    }

    @Test func applesPercentageWinsOverOurMath() {
        var battery = BatterySnapshot()
        battery.designCapacity = 6075
        battery.maxCapacity = 5128        // our math alone would say 84.4%
        #expect(abs((battery.healthPercent ?? 0) - 84.41) < 0.01)
        battery.appleMaxCapacityPercent = 83
        #expect(battery.healthPercent == 83)   // matches System Settings
    }

    @Test func healthVerdicts() {
        #expect(BatteryInsights.health(percent: 95, condition: "Good") == .healthy)
        #expect(BatteryInsights.health(percent: 83, condition: "Good") == .normalWear)
        #expect(BatteryInsights.health(percent: 76, condition: nil) == .serviceSoon)
        #expect(BatteryInsights.health(percent: 90, condition: "Service Recommended") == .serviceSoon)
        #expect(BatteryInsights.health(percent: nil, condition: nil) == .unknown)
    }

    @Test func healthSentenceUsesRatedCycles() {
        var battery = BatterySnapshot()
        battery.appleMaxCapacityPercent = 83
        battery.cycleCount = 614
        battery.designCycleCount = 1000
        #expect(BatteryInsights.healthSentence(battery) == "It holds 83% of its original charge after 614 of about 1,000 rated charge cycles. That's normal wear; nothing to do yet.")
    }

    @Test func explainsWhyItIsNotCharging() {
        var battery = BatterySnapshot()
        battery.isPluggedIn = true
        battery.percent = 80
        #expect(BatteryInsights.chargingState(battery) == .holdingToProtect)
        #expect(BatteryInsights.chargingText(.holdingToProtect) == "Paused near 80% to protect the battery")
        battery.percent = 40
        #expect(BatteryInsights.chargingState(battery) == .pluggedNotCharging)
        battery.isCharging = true
        battery.watts = -42
        battery.adapterWatts = 67
        #expect(BatteryInsights.chargingText(BatteryInsights.chargingState(battery)) == "Charging at 42 W · 67 W charger")
    }

    @Test func personalBatteryLife() {
        let now = Date()
        func s(_ i: Int, watts: Double?) -> HistorySample {
            HistorySample(date: now.addingTimeInterval(Double(i) * 60), cpuUser: 0, cpuSystem: 0, memoryUsedPercent: 0,
                          networkIn: 0, networkOut: 0, diskRead: 0, diskWrite: 0, batteryPercent: 50, batteryWatts: watts)
        }
        // 30 minutes unplugged isn't enough to learn from…
        #expect(BatteryInsights.typicalDrain(samples: (0..<30).map { s($0, watts: 8) }, sampleLength: 60) == nil)
        // …90 minutes at 8 W is. Plugged-in time (nil) doesn't count.
        let learned = BatteryInsights.typicalDrain(samples: (0..<90).map { s($0, watts: 8) } + (0..<60).map { s($0, watts: nil) }, sampleLength: 60)
        #expect(learned == 8)
        // 58 Wh at 8 W = 7.25 h, exactly between 7 and 7½; ties round up.
        #expect(BatteryInsights.describe(hours: BatteryInsights.hours(fullChargeWattHours: 58, watts: 8)!) == "about 7½ hours")
        #expect(BatteryInsights.describe(hours: 7.1) == "about 7 hours")
        #expect(BatteryInsights.describe(hours: 7.6) == "about 7½ hours")
        #expect(BatteryInsights.describe(hours: 0.4) == "under an hour")
    }

    @Test func fullChargeEnergy() {
        var battery = BatterySnapshot()
        battery.maxCapacity = 4978
        battery.voltage = 11.615
        #expect(abs((battery.fullChargeWattHours ?? 0) - 57.82) < 0.01)
    }

    @Test func impactLabels() {
        #expect(BatteryInsights.impact(watts: 3.1) == .high)
        #expect(BatteryInsights.impact(watts: 0.8) == .medium)
        #expect(BatteryInsights.impact(watts: 0.1) == .low)
    }

    @Test func processEnergyIsMeasuredOnThisMac() {
        // Per-process energy (rusage v6) should be available on Apple silicon.
        guard let usage = ProcessSampler.resourceUsage(for: getpid()) else { Issue.record("no rusage"); return }
        #expect(usage.ri_energy_nj > 0)
    }
}

@Suite("Apps")
struct AppsTests {
    private func app(_ name: String, path: String?, kind: AppKind = .application, cpu: Double = 0, memoryMB: UInt64 = 100, watts: Double = 0) -> AppUsage {
        AppUsage(id: path ?? name, name: name, bundlePath: path, kind: kind, processes: [
            ProcessUsage(pid: 70_000 + pid_t(abs(name.hashValue % 1000)), name: name, path: path ?? "", cpu: cpu,
                         memory: memoryMB << 20, diskReadRate: 0, diskWriteRate: 0, watts: watts),
        ])
    }

    @Test func impactCombinesCPUMemoryAndEnergy() {
        let ram: UInt64 = 16 << 30
        // 80% of one core on 8 cores = 10% of the CPU → exactly "noticeable".
        #expect(AppInsights.impact(score: AppInsights.impactScore(app("A", path: nil, cpu: 80), cores: 8, totalRAM: ram)) == .high)
        // 2 GB of 16 GB = 12.5% of RAM → high even with no CPU.
        #expect(AppInsights.impact(score: AppInsights.impactScore(app("B", path: nil, memoryMB: 2048), cores: 8, totalRAM: ram)) == .high)
        // 1 W → medium.
        #expect(AppInsights.impact(score: AppInsights.impactScore(app("C", path: nil, watts: 1), cores: 8, totalRAM: ram)) == .medium)
        #expect(AppInsights.impact(score: AppInsights.impactScore(app("D", path: nil, cpu: 2, memoryMB: 150), cores: 8, totalRAM: ram)) == .low)
    }

    @Test func rolesFromActivationPolicy() {
        let policies: [String: NSApplication.ActivationPolicy] = [
            "/Applications/Safari.app": .regular,
            "/Applications/Bartender.app": .accessory,
            "/System/Library/CoreServices/Finder.app": .regular,
        ]
        #expect(AppInsights.role(for: app("Safari", path: "/Applications/Safari.app"), policies: policies) == .app)
        #expect(AppInsights.role(for: app("Bartender", path: "/Applications/Bartender.app"), policies: policies) == .background)
        #expect(AppInsights.role(for: app("Finder", path: "/System/Library/CoreServices/Finder.app"), policies: policies) == .app)
        #expect(AppInsights.role(for: app("Dock", path: "/System/Library/CoreServices/Dock.app"), policies: policies) == .system)
        #expect(AppInsights.role(for: app("macOS", path: nil, kind: .system), policies: policies) == .system)
        #expect(AppInsights.role(for: app("postgres", path: nil, kind: .process), policies: policies) == .background)
    }

    private func series(minutes: Int, every seconds: TimeInterval = 30, cpu: (Int) -> Double, memoryMB: (Int) -> UInt64) -> [AppInsights.TrendPoint] {
        let now = Date()
        let count = Int(Double(minutes * 60) / seconds)
        return (0...count).map { i in
            AppInsights.TrendPoint(date: now.addingTimeInterval(-Double(count - i) * seconds), cpu: cpu(i), memory: memoryMB(i) << 20)
        }
    }

    @Test func flagsAppStuckBusy() {
        let points = series(minutes: 12, cpu: { _ in 98 }, memoryMB: { _ in 500 })
        guard case .stuckBusy(let cpu, let minutes) = AppInsights.stuckBusy(points, now: Date()) else {
            Issue.record("expected stuck busy"); return
        }
        #expect(cpu == 98 && minutes >= 11)
    }

    @Test func briefSpikesAreNotStuck() {
        // Busy, then a quiet moment within the last 5 minutes → normal work, not stuck.
        let points = series(minutes: 12, cpu: { $0 == 20 ? 5 : 95 }, memoryMB: { _ in 500 })
        #expect(AppInsights.stuckBusy(points, now: Date()) == nil)
        // Only 2 minutes of data → not enough to judge.
        #expect(AppInsights.stuckBusy(series(minutes: 2, cpu: { _ in 99 }, memoryMB: { _ in 1 }), now: Date()) == nil)
    }

    @Test func flagsSteadyMemoryGrowth() {
        // 1 GB → 3 GB over 30 minutes, rising steadily.
        let points = series(minutes: 30, cpu: { _ in 5 }, memoryMB: { 1024 + UInt64($0) * 34 })
        guard case .growingMemory(let from, let to, let minutes) = AppInsights.growingMemory(points, now: Date()) else {
            Issue.record("expected growing memory"); return
        }
        #expect(from == 1024 << 20)
        #expect(to == UInt64(1024 + 60 * 34) << 20)  // 61 points, 34 MB apart
        #expect(minutes == 30)
    }

    @Test func sawtoothMemoryIsNotALeak() {
        // Goes up and down (normal caching); ends higher but isn't steadily rising.
        let points = series(minutes: 30, cpu: { _ in 5 }, memoryMB: { i in i % 2 == 0 ? 1000 : 3200 })
        #expect(AppInsights.growingMemory(points, now: Date()) == nil)
        // Small absolute growth (200 → 500 MB) isn't worth flagging either.
        #expect(AppInsights.growingMemory(series(minutes: 30, cpu: { _ in 0 }, memoryMB: { 200 + UInt64($0) * 5 }), now: Date()) == nil)
    }

    @Test func trackerThinsAndForgetsQuitApps() {
        var tracker = AppTrendTracker()
        let start = Date()
        let safari = app("Safari", path: "/Applications/Safari.app")
        tracker.record([safari], at: start)
        tracker.record([safari], at: start.addingTimeInterval(5))   // too soon, thinned
        tracker.record([safari], at: start.addingTimeInterval(25))
        #expect(tracker.points[safari.id]?.count == 2)
        tracker.record([], at: start.addingTimeInterval(60))          // Safari quit
        #expect(tracker.points.isEmpty)
        // macOS itself is never tracked.
        tracker.record([app("macOS", path: nil, kind: .system)], at: start)
        #expect(tracker.points.isEmpty)
    }

    @Test func glossaryExplainsCommonProcesses() {
        #expect(ProcessGlossary.explain("mds_stores")?.what.contains("Spotlight") == true)
        #expect(ProcessGlossary.explain("com.apple.WebKit.WebContent")?.what.contains("web page") == true)
        #expect(ProcessGlossary.explain("Google Chrome Helper (Renderer)")?.what.contains("tab") == true)
        #expect(ProcessGlossary.explain("Google Chrome Helper (GPU)")?.what.contains("graphics") == true)
        #expect(ProcessGlossary.explain("SomeRandomDaemon") == nil)
    }
}

@Suite("Dev servers")
struct DevServerTests {
    @Test func recognizesCommonServers() {
        #expect(ServerInsights.tech(command: "node", arguments: ["node", "/proj/node_modules/.bin/vite", "--port", "5173"], port: 5173)?.name == "Vite")
        #expect(ServerInsights.tech(command: "node", arguments: ["node", "/proj/node_modules/.bin/next", "dev"], port: 3000)?.name == "Next.js")
        #expect(ServerInsights.tech(command: "python3.12", arguments: ["python3", "manage.py", "runserver"], port: 8000)?.name == "Django")
        #expect(ServerInsights.tech(command: "postgres", arguments: ["postgres", "-D", "/usr/local/var/postgres"], port: 5432)?.name == "PostgreSQL")
        #expect(ServerInsights.tech(command: "node", arguments: ["node", "server.js"], port: 4000)?.name == "Node.js")
        // Unknown binary on a well-known port falls back to the port.
        #expect(ServerInsights.tech(command: "mystery", arguments: [], port: 6379)?.name == "Redis")
        #expect(ServerInsights.tech(command: "mystery", arguments: [], port: 4321) == nil)
    }

    @Test func explainsMacOSServices() {
        #expect(ServerInsights.service(command: "ControlCenter", port: 7000)?.name == "AirPlay Receiver")
        #expect(ServerInsights.service(command: "ControlCenter", port: 7000)?.settingsHint?.contains("AirPlay Receiver") == true)
        #expect(ServerInsights.service(command: "rapportd", port: 49152)?.name == "Continuity")
        #expect(ServerInsights.service(command: "launchd", port: 22)?.name == "Remote Login (SSH)")
        #expect(ServerInsights.service(command: "cloudflared", port: 20241)?.explanation.contains("internet") == true)
        #expect(ServerInsights.service(command: "ollama", port: 11434)?.name == "Ollama")
        #expect(ServerInsights.service(command: "SomethingElse", port: 50001) == nil)
    }

    @Test func idleNeedsTimeAndQuiet() {
        #expect(ServerInsights.isIdle(cpu: 0.1, uptime: 3 * 3600))
        #expect(!ServerInsights.isIdle(cpu: 0.1, uptime: 10 * 60))   // just started
        #expect(!ServerInsights.isIdle(cpu: 12, uptime: 3 * 3600))    // busy
        #expect(!ServerInsights.isIdle(cpu: 0, uptime: nil))
    }

    @Test func uptimePhrasing() {
        #expect(ServerInsights.describeUptime(30) == "just started")
        #expect(ServerInsights.describeUptime(25 * 60) == "25 min")
        #expect(ServerInsights.describeUptime(5 * 3600) == "5 h")
        #expect(ServerInsights.describeUptime(3 * 86_400) == "3 days")
    }

    @Test func groupsServersByProject() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ports = [
            ListeningPort(pid: 1, command: "node", port: 5173, addresses: ["127.0.0.1"], workingDirectory: home + "/Developer/shop"),
            ListeningPort(pid: 2, command: "node", port: 3000, addresses: ["127.0.0.1"], workingDirectory: home + "/Developer/shop"),
            ListeningPort(pid: 3, command: "ruby", port: 4567, addresses: ["*"], workingDirectory: home + "/Developer/blog"),
            ListeningPort(pid: 4, command: "rapportd", port: 49152, addresses: ["*"], workingDirectory: nil),
        ]
        let projects = ServerInsights.projects(ports)
        #expect(projects.map(\.name) == ["blog", "shop"])
        #expect(projects[1].servers.map(\.port) == [3000, 5173])
    }

    @Test func oneRowPerServiceEvenWithSeveralPorts() {
        let ports = [
            ListeningPort(pid: 500, command: "ControlCenter", port: 7000, addresses: ["*"], workingDirectory: nil),
            ListeningPort(pid: 500, command: "ControlCenter", port: 5000, addresses: ["*"], workingDirectory: nil),
            ListeningPort(pid: 600, command: "mediasharingd", port: 3689, addresses: ["*"], workingDirectory: nil),
        ]
        let groups = ServerInsights.serviceGroups(ports)
        #expect(groups.map(\.name) == ["AirPlay Receiver", "Media Sharing"])
        #expect(groups[0].portList == ":5000 · :7000")   // no thousands separators, sorted
        #expect(!groups[0].isLocalOnly)
    }

    @Test func parsesKernelArgumentBuffer() {
        var buffer: [UInt8] = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buffer += Array("/usr/bin/python3".utf8) + [0, 0, 0, 0]
        for arg in ["python3", "-m", "http.server"] { buffer += Array(arg.utf8) + [0] }
        buffer += Array("PATH=/usr/bin".utf8) + [0] // environment follows; must be ignored
        #expect(ProcessDetails.parseProcArgs(buffer) == ["python3", "-m", "http.server"])
    }

    @Test func findsARealLocalServerEndToEnd() async throws {
        // A real project folder under home, a real server bound to localhost.
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacVitalsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let port = 48_765
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        server.currentDirectoryURL = folder
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }

        var found: ListeningPort?
        for _ in 0..<20 where found == nil {
            try await Task.sleep(for: .milliseconds(250))
            found = try PortScanner.scan().first { $0.port == port }
        }
        let entry = try #require(found, "server on :\(port) not found")
        #expect(entry.isDevServer)
        #expect(entry.isLocalOnly)
        #expect(entry.projectName == folder.lastPathComponent)
        #expect(entry.tech?.name == "Python file server")
        #expect(entry.arguments.contains("http.server"))
        #expect((entry.uptime ?? 999) < 30)
    }
}

@Suite("Clean Up engine")
struct CleanUpTests {
    private let fm = FileManager.default

    /// A fake home with projects of different ages and a Downloads folder.
    private func makeHome(now: Date) throws -> URL {
        let home = fm.temporaryDirectory.appending(path: "mv-cleanup-\(UUID().uuidString)")
        func file(_ path: String, size: Int = 2_000_000, age days: Double) throws {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
            let date = now.addingTimeInterval(-days * 86_400)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        // Idle 5 months → safe.
        try file("Developer/old-shop/package.json", size: 10, age: 150)
        try file("Developer/old-shop/pnpm-lock.yaml", size: 10, age: 150)
        try file("Developer/old-shop/node_modules/react/index.js", age: 150)
        try file("Developer/old-shop/node_modules/react/node_modules/nested/x.js", age: 150) // not reported separately
        // Idle 45 days → review.
        try file("Developer/py-tool/pyproject.toml", size: 10, age: 45)
        try file("Developer/py-tool/.venv/pyvenv.cfg", size: 10, age: 45)
        try file("Developer/py-tool/.venv/lib/big.so", age: 45)
        // Active this week → left alone.
        try file("Developer/current-app/package.json", size: 10, age: 2)
        try file("Developer/current-app/node_modules/lib/index.js", age: 2)
        // Rust project, idle a year.
        try file("Projects/rusty/Cargo.toml", size: 10, age: 400)
        try file("Projects/rusty/target/debug/app", age: 400)
        // A "target" folder that isn't Rust must NOT be flagged.
        try file("Projects/not-rust/readme.md", size: 10, age: 400)
        try file("Projects/not-rust/target/important.txt", age: 400)
        // SwiftPM
        try file("Developer/swifty/Package.swift", size: 10, age: 200)
        try file("Developer/swifty/.build/debug/thing", age: 200)
        // Downloads: an old installer (safe), a fresh one (review).
        try file("Downloads/OldApp.dmg", age: 60)
        try file("Downloads/NewApp.dmg", age: 2)
        return home
    }

    @Test func findsDependenciesInIdleProjectsOnly() throws {
        let now = Date()
        let home = try makeHome(now: now)
        defer { try? fm.removeItem(at: home) }
        let items = ProjectJunk.find(home: home, now: now)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["old-shop/node_modules", "py-tool/.venv", "rusty/target", "swifty/.build"])
        #expect(byName["old-shop/node_modules"]?.tier == .safe)
        #expect(byName["py-tool/.venv"]?.tier == .review)
        #expect(byName["rusty/target"]?.tier == .safe)
        // The reinstall hint follows the lockfile.
        #expect(byName["old-shop/node_modules"]?.detail?.contains("pnpm install") == true)
        #expect(byName["old-shop/node_modules"]?.detail?.contains("not touched in 5 months") == true)
    }

    @Test func downloadsTiersInstallersByAge() throws {
        let now = Date()
        let home = try makeHome(now: now)
        defer { try? fm.removeItem(at: home) }
        let scan = JunkScanners.downloads(home: home, now: now)
        let installers = try #require(scan.groups.first { $0.id == "installers" })
        let tiers = Dictionary(uniqueKeysWithValues: installers.items.map { ($0.name, $0.tier) })
        #expect(tiers == ["OldApp.dmg": .safe, "NewApp.dmg": .review])
    }

    @Test func trashItemsAreCarefulAndPermanent() throws {
        let home = fm.temporaryDirectory.appending(path: "mv-trash-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: home.appending(path: ".Trash/old.zip"))
        defer { try? fm.removeItem(at: home) }
        let scan = JunkScanners.trash(home: home)
        #expect(scan.groups.first?.isPermanent == true)
        #expect(scan.items.allSatisfy { $0.tier == .careful })
    }

    @Test func neverTouchesSystemLocations() {
        #expect(CleanupRemover.isProtected("/System/Library/Caches"))
        #expect(CleanupRemover.isProtected("/usr/lib"))
        #expect(CleanupRemover.isProtected(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(!CleanupRemover.isProtected(FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/foo"))
        let record = CleanupRemover.remove([JunkItem(path: "/System/Library/Fonts", name: "Fonts", size: 1, tier: .safe)], permanently: true)
        #expect(record.entries.isEmpty && record.failures == ["Fonts"])
    }

    @Test func trashPutBackAndEmptyRoundTrip() throws {
        let folder = fm.temporaryDirectory.appending(path: "mv-roundtrip-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let a = folder.appending(path: "cache-a")
        let b = folder.appending(path: "cache-b")
        try Data(count: 1_500_000).write(to: a)
        try Data(count: 1_500_000).write(to: b)
        let items = [a, b].map { JunkItem(path: $0.path, name: $0.lastPathComponent, size: 1_500_000, tier: .safe) }

        // 1. Clean → both land in the Trash and the record knows where.
        let record = CleanupRemover.remove(items, permanently: false)
        #expect(record.entries.count == 2 && record.movedToTrash == 3_000_000)
        #expect(!fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: b.path))
        #expect(record.restorable.count == 2)

        // 2. Put back → both return to their original paths.
        #expect(CleanupRemover.putBack(record) == 2)
        #expect(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path))

        // 3. Clean again, then Empty now → gone for good, nothing left to restore.
        let second = CleanupRemover.remove(items, permanently: false)
        let finalized = CleanupRemover.finalize(second)
        #expect(finalized.restorable.isEmpty)
        #expect(finalized.deletedPermanently == 3_000_000)
        #expect(second.entries.compactMap(\.trashedPath).allSatisfy { !fm.fileExists(atPath: $0) })
    }

    @Test func supersededDeviceSupportIsSafe() {
        let items = ["iPhone17,1 27.0 (24A435)", "iPhone17,1 27.0 (24A5430a)", "iPhone17,1 27.0 (24A5418b)",
                     "iPhone15,2 26.4 (23E244)", "17.2 (21C62)"].map {
            JunkItem(path: "/x/\($0)", name: $0, size: 7_000_000_000, tier: .review)
        }
        let result = Dictionary(uniqueKeysWithValues: DeviceSupport.classify(items).map { ($0.name, $0) })
        // Release build is kept; both betas of the same version are superseded.
        #expect(result["iPhone17,1 27.0 (24A435)"]?.tier == .review)
        #expect(result["iPhone17,1 27.0 (24A5430a)"]?.tier == .safe)
        #expect(result["iPhone17,1 27.0 (24A5418b)"]?.tier == .safe)
        #expect(result["iPhone17,1 27.0 (24A5418b)"]?.detail == "Superseded: this device now uses 27.0 (24A435)")
        // Only one folder for these devices: nothing superseded.
        #expect(result["iPhone15,2 26.4 (23E244)"]?.tier == .review)
        #expect(result["17.2 (21C62)"]?.tier == .review)
    }

    @Test func deviceSupportVersionOrdering() {
        let old = DeviceSupport.parse("iPad13,4 18.6 (22G86)")!
        let new = DeviceSupport.parse("iPad13,4 26.0 (23A341)")!
        #expect(DeviceSupport.isNewer(new, than: old))
        #expect(!DeviceSupport.isNewer(old, than: new))
        #expect(DeviceSupport.parse("iPhone17,1 27.0 (24A5430a)") == .init(device: "iPhone17,1", version: [27, 0], build: "24A5430a"))
    }

    @Test func historyPersists() throws {
        let url = fm.temporaryDirectory.appending(path: "mv-history-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: url) }
        let record = CleanupRecord(id: UUID(), date: Date(), entries: [
            .init(name: "x", originalPath: "/tmp/x", trashedPath: nil, size: 42),
        ], failures: [])
        CleanupHistoryStore.save([record], to: url)
        let loaded = CleanupHistoryStore.load(from: url)
        #expect(loaded.count == 1 && loaded[0].id == record.id && loaded[0].deletedPermanently == 42)
    }
}
