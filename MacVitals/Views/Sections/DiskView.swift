import SwiftUI
import AppKit

/// Disk page. For everyone: how full it is, when it'll run out, what's taking up the space,
/// and the quickest wins. For technical users, "Under the hood": drive health, read/write
/// activity and which apps are hitting the disk.
struct DiskView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Router.self) private var router
    @Environment(CleanupEngine.self) private var cleanup
    @Environment(StorageModel.self) private var storage
    @AppStorage(SettingsKeys.historyRange) private var rangeRaw = HistoryRange.hour.rawValue
    @State private var driveHealth: String?

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .hour }

    private var forecast: DiskInsights.Forecast {
        DiskInsights.forecast(samples: monitor.history(for: .month), currentFree: monitor.disk.availableCapacity)
    }

    var body: some View {
        SectionScroll {
            verdict.entrance()
            stats.entrance(delay: 0.04)
            StorageBreakdownCard().entrance(delay: 0.08)
            HStack(alignment: .top, spacing: 16) {
                reclaimable
                LargestFilesCard()
            }
            .fixedSize(horizontal: false, vertical: true)
            .entrance(delay: 0.12)
            freeSpaceHistory.entrance(delay: 0.16)

            underTheHoodHeader
            activityStats
            activity
            topApps
        }
        .task {
            await storage.refreshIfStale()
        }
        .task {
            driveHealth = await DriveHealth.status()
        }
    }

    // MARK: Verdict

    private var verdict: some View {
        let disk = monitor.disk
        let level = DiskInsights.level(freePercent: disk.freePercent)
        let tint = Theme.diskLevel(level)
        let free = Fmt.splitBytes(disk.availableCapacity)
        let forecast = forecast

        return HStack(spacing: 22) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(1, disk.usedPercent / 100))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: disk.usedPercent)
                // Number and unit on separate lines so it never wraps mid-value.
                VStack(spacing: 0) {
                    Text(free.number)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .rollingNumber(free.number)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(free.unit) free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your disk \(level.title)")
                    .font(.title2.weight(.semibold))
                    .contentTransition(.interpolate)
                    .animation(.smooth, value: level)
                Text(level.sentence)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    switch forecast {
                    case .runsOut(let days):
                        InfoChip(text: forecast.headline, icon: "calendar.badge.exclamationmark",
                                 tint: days < 30 ? .orange : .secondary)
                            .help(forecast.sentence)
                    case .steady, .freeingUp:
                        InfoChip(text: forecast.headline, icon: "checkmark.circle", tint: .green)
                            .help(forecast.sentence)
                    case .collecting:
                        EmptyView()
                    }
                    if DiskInsights.tooSmallForUpdates(available: disk.availableCapacity) {
                        InfoChip(text: "macOS updates need ~25 GB free", icon: "arrow.down.circle", tint: .orange)
                            .help("Major macOS updates need roughly 25 GB of free space to download and install.")
                    }
                    if level != .plenty {
                        Button {
                            router.section = .cleanup
                        } label: {
                            Label("Free Up Space", systemImage: "sparkles")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.cleanup)
                        .controlSize(.small)
                        .pointerStyle(.link)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    // MARK: Stats (everyday)

    private var stats: some View {
        let disk = monitor.disk
        let forecast = forecast
        return HStack(spacing: 16) {
            DetailStat(
                label: "Free", term: "Available",
                value: Fmt.bytes(disk.availableCapacity),
                tint: disk.freePercent < 10 ? Theme.diskLevel(DiskInsights.level(freePercent: disk.freePercent)) : nil,
                caption: "\(Fmt.percent(disk.freePercent)) of the disk",
                help: "Space available for new files, including space macOS clears on its own when needed."
            )
            DetailStat(
                label: "Used", term: "Used",
                value: Fmt.bytes(disk.usedCapacity),
                caption: "of \(Fmt.bytes(disk.totalCapacity))",
                help: "Everything stored on the startup disk: macOS, apps, your files and caches."
            )
            DetailStat(
                label: "Clears on its own", term: "Purgeable",
                value: Fmt.bytes(disk.purgeableCapacity),
                caption: "Counted as free already",
                help: "Caches and local Time Machine snapshots macOS deletes automatically when it needs space."
            )
            DetailStat(
                label: "Forecast", term: "Trend",
                value: forecastValue(forecast),
                tint: forecastTint(forecast),
                caption: forecastCaption(forecast),
                help: "Projected from how your free space has changed over the history Mac Vitals has recorded."
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func forecastValue(_ forecast: DiskInsights.Forecast) -> String {
        switch forecast {
        case .collecting: "Learning…"
        case .steady: "Steady"
        case .freeingUp: "Growing"
        case .runsOut(let days): days < 60 ? "\(Int(days.rounded())) days" : "\(Int((days / 30).rounded())) months"
        }
    }

    private func forecastCaption(_ forecast: DiskInsights.Forecast) -> String {
        switch forecast {
        case .collecting(let hours): "Ready in about \(hours) h"
        case .steady: "Not running out any time soon"
        case .freeingUp: "You've been freeing up space"
        case .runsOut: "Until full, at the current rate"
        }
    }

    private func forecastTint(_ forecast: DiskInsights.Forecast) -> Color? {
        if case .runsOut(let days) = forecast { return days < 30 ? .orange : nil }
        return nil
    }

    // MARK: Reclaimable

    private var reclaimable: some View {
        Card("Quick wins", systemImage: "sparkles", tint: Theme.cleanup) {
            switch cleanup.phase {
            case .idle:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Caches, logs, developer junk and old installers you can safely clear. Nothing is removed until you review it.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await cleanup.scan() }
                    } label: {
                        Label("Find reclaimable space", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.cleanup)
                    .pointerStyle(.link)
                }
            case .scanning where cleanup.scans.isEmpty:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for junk…").foregroundStyle(.secondary)
                }
            default:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Fmt.bytes(cleanup.totalFound))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.cleanup)
                        Text("of junk found").foregroundStyle(.secondary)
                    }
                    if cleanup.safeTotal > 0 {
                        Text("\(Fmt.bytes(cleanup.safeTotal)) is safe to remove right now.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(cleanup.orderedScans.filter { $0.totalSize > 0 }) { scan in
                        HStack(spacing: 10) {
                            Image(systemName: scan.module.icon)
                                .foregroundStyle(Theme.cleanup)
                                .frame(width: 20)
                            Text(scan.module.title).lineLimit(1)
                            Spacer()
                            Text(Fmt.bytes(scan.totalSize)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        } accessory: {
            if cleanup.phase == .ready {
                Button("Review") { router.section = .junk }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerStyle(.link)
            }
        }
        .fillingHeight()
    }

    // MARK: Free space trend

    private var freeSpaceHistory: some View {
        let samples = monitor.history(for: range)
        let change = DiskInsights.freeSpaceChange(samples)
        let tint = Theme.diskLevel(DiskInsights.level(freePercent: monitor.disk.freePercent))
        let start = monitor.historyStart
        let partial = start.map { $0 > Date().addingTimeInterval(-range.duration + range.resolution * 2) } ?? true

        return Card("Free space over time", systemImage: "chart.line.downtrend.xyaxis", tint: Theme.disk) {
            HistoryChart(
                points: monitor.points(\.diskFree, series: "Free space", range: range),
                series: [.init(name: "Free space", color: tint)],
                range: range,
                format: { Fmt.bytes(Int64(max(0, $0))) }
            )
            .frame(height: 160)
            Text(forecast.sentence)
                .font(.caption)
                .foregroundStyle(.secondary)
            if partial, let start {
                Label("Collecting since \(start.formatted(date: range == .hour || range == .day ? .omitted : .abbreviated, time: .shortened)). Trends become clearer over days.",
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } accessory: {
            HStack(spacing: 14) {
                if let change {
                    HStack(spacing: 4) {
                        Image(systemName: change < 0 ? "arrow.down.right" : "arrow.up.right")
                        Text((change < 0 ? "−" : "+") + Fmt.bytes(Int64(abs(change))) + " in \(range.label)")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(change < -5_000_000_000 ? .orange : .secondary)
                }
                HistoryRangePicker()
            }
        }
    }

    // MARK: Under the hood

    private var underTheHoodHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Under the hood")
                .font(.title3.weight(.semibold))
            Text("Drive health and read/write activity, for when you want the technical details.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    private var activityStats: some View {
        let disk = monitor.disk
        return HStack(spacing: 16) {
            DetailStat(
                label: "Drive health", term: "S.M.A.R.T.",
                value: driveHealth ?? "Checking…",
                tint: driveHealth == "Verified" ? .green : (driveHealth == nil ? nil : .red),
                caption: driveHealth == "Verified" ? "No problems reported" : "Reported by the SSD itself",
                help: "The SSD's own self-test status. \"Verified\" means it reports no problems. Wear level is coming soon."
            )
            DetailStat(
                label: "Reading", term: "Read",
                value: Fmt.rate(disk.readRate),
                caption: "Loading files and apps"
            )
            DetailStat(
                label: "Writing", term: "Write",
                value: Fmt.rate(disk.writeRate),
                caption: "Saving files, caches and swap"
            )
            DetailStat(
                label: "Written", term: "Session",
                value: Fmt.bytes(disk.sessionWritten),
                caption: "Since Mac Vitals started",
                help: "Total data written to the SSD while Mac Vitals has been running. SSDs wear slowly with writes."
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var activity: some View {
        let samples = monitor.history(for: range)
        return Card("Activity", systemImage: "arrow.up.arrow.down", tint: Theme.disk) {
            HistoryChart(
                points: monitor.points(\.diskRead, series: "Reading", range: range)
                    + monitor.points(\.diskWrite, series: "Writing", range: range),
                series: [.init(name: "Reading", color: .blue), .init(name: "Writing", color: Theme.disk)],
                range: range,
                format: { Fmt.rate($0) }
            )
            .frame(height: 160)
        } accessory: {
            HStack(spacing: 14) {
                if !samples.isEmpty {
                    summaryValue("Peak read", Fmt.rate(samples.map(\.diskRead).max() ?? 0))
                    summaryValue("Peak write", Fmt.rate(samples.map(\.diskWrite).max() ?? 0))
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

    private var topApps: some View {
        let ranked = Array(monitor.apps.filter { $0.diskTotalRate > 0 }.sorted { $0.diskTotalRate > $1.diskTotalRate }.prefix(8))
        let maxRate = max(ranked.first?.diskTotalRate ?? 1, 1)
        return Card("Apps reading & writing", systemImage: "list.number", tint: Theme.disk) {
            VStack(spacing: 10) {
                if ranked.isEmpty {
                    Text("Nothing is reading or writing much right now.")
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
                                Text("R \(Fmt.rate(app.diskReadRate))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Text("W \(Fmt.rate(app.diskWriteRate))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .trailing)
                            }
                            MeterBar(fraction: app.diskTotalRate / maxRate, tint: Theme.disk, height: 4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - What's taking up space

private struct StorageBreakdownCard: View {
    @Environment(StorageModel.self) private var storage
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Permissions.self) private var permissions
    @State private var expanded: Set<StorageKind> = []

    var body: some View {
        Card("What's taking up space", systemImage: "chart.bar.doc.horizontal", tint: Theme.disk) {
            if !storage.hasConsented && storage.report == nil {
                primer
            } else if storage.phase == .scanning && storage.report == nil {
                scanningView
            } else if let report = storage.report {
                breakdown(report)
            }
        } accessory: {
            if let report = storage.report {
                HStack(spacing: 8) {
                    if storage.phase == .scanning {
                        ProgressView(value: storage.progress).frame(width: 60).controlSize(.small)
                    } else {
                        Text("Scanned \(report.scannedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Rescan") { Task { await storage.scan() } }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .pointerStyle(.link)
                        .disabled(storage.phase == .scanning)
                }
            }
        }
    }

    /// Explain before macOS asks (the pattern the best Mac apps use).
    private var primer: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "externaldrive.fill.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(Theme.disk.gradient)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 10) {
                Text("See what's filling your Mac")
                    .font(.headline)
                Text("Mac Vitals adds up the size of your apps, files, photos, developer data and more, so you can see where your space went.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Label("macOS will ask to let Mac Vitals see Documents, Desktop and Downloads. Click **Allow**.", systemImage: "hand.raised")
                    Label("Only sizes are read, never what's inside your files.", systemImage: "eye.slash")
                    Label("Nothing leaves your Mac.", systemImage: "lock")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Button {
                    Task { await storage.scan() }
                } label: {
                    Label("Scan storage", systemImage: "sparkle.magnifyingglass")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.disk)
                .controlSize(.large)
                .pointerStyle(.link)
                .padding(.top, 4)
            }
        }
    }

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: storage.progress)
                .tint(Theme.disk)
            FlowChips(kinds: StorageKind.allCases, finished: storage.finishedKinds)
            Text("This takes about a minute the first time. You can keep using your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func breakdown(_ report: StorageReport) -> some View {
        let used = monitor.disk.usedCapacity
        let other = report.systemAndOther(used: used)
        let categories = report.categories.filter { $0.size > 0 || $0.needsAccess }.sorted { $0.size > $1.size }
        var segments = categories.filter { $0.size > 0 }.map {
            SegmentedBar.Segment(label: $0.kind.title, value: Double($0.size), color: Theme.storage($0.kind))
        }
        if other > 0 {
            segments.append(.init(label: "macOS, system & other", value: Double(other), color: .gray.opacity(0.45)))
        }
        segments.append(.init(label: "Free", value: Double(monitor.disk.availableCapacity), color: .gray.opacity(0.15)))

        return VStack(alignment: .leading, spacing: 14) {
            SegmentedBar(segments: segments, height: 20)

            VStack(spacing: 4) {
                ForEach(categories) { category in
                    CategoryRow(category: category, used: used, isExpanded: expanded.contains(category.kind)) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            if expanded.contains(category.kind) { expanded.remove(category.kind) } else { expanded.insert(category.kind) }
                        }
                    }
                }
                if other > 0 {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(.gray.opacity(0.45)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("macOS, system & other").font(.callout.weight(.medium))
                            Text("macOS itself, system data, other users and anything Mac Vitals can't see.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.bytes(other)).monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }

            if storage.needsFullDiskAccess && !permissions.hasFullDiskAccess {
                FullDiskAccessBanner {
                    permissions.onFullDiskAccessGranted = { Task { await storage.scan() } }
                    permissions.requestFullDiskAccess()
                }
            }
            if storage.needsFolderAccess {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange)
                    Text("Some folders were blocked. Allow Mac Vitals under Files & Folders to include them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerStyle(.link)
                }
            }
        }
    }
}

private struct CategoryRow: View {
    let category: StorageCategory
    let used: Int64
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.storage(category.kind))
                        .frame(width: 10, height: 10)
                    Image(systemName: category.kind.icon)
                        .foregroundStyle(Theme.storage(category.kind))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.kind.title).font(.callout.weight(.medium))
                        Text(category.kind.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if category.needsAccess && category.size == 0 {
                        Text("Needs access").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    } else {
                        Text(Fmt.bytes(category.size)).monospacedDigit()
                        Text(Fmt.percent(used > 0 ? Double(category.size) / Double(used) * 100 : 0))
                            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(category.largest.isEmpty ? 0 : 1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(category.largest.isEmpty)
            .onHover { hovering = $0 }

            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(category.largest) { item in
                        StorageItemRow(item: item)
                    }
                }
                .padding(.leading, 46)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct StorageItemRow: View {
    let item: StorageItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Fmt.bytes(item.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Button {
                ProcessController.revealInFinder(item.path)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.4)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }
}

/// Chips that light up as each category finishes scanning.
private struct FlowChips: View {
    let kinds: [StorageKind]
    let finished: Set<StorageKind>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(kinds) { kind in
                let done = finished.contains(kind)
                HStack(spacing: 6) {
                    Image(systemName: done ? "checkmark.circle.fill" : kind.icon)
                        .foregroundStyle(done ? Theme.storage(kind) : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(kind.title).font(.caption).lineLimit(1)
                }
                .opacity(done ? 1 : 0.55)
                .animation(.spring(response: 0.4), value: done)
            }
        }
    }
}

/// Inline, optional, non-blocking: the app works fine without it.
private struct FullDiskAccessBanner: View {
    let request: () -> Void
    @Environment(Permissions.self) private var permissions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.open.display")
                .font(.title2)
                .foregroundStyle(Theme.disk)
            VStack(alignment: .leading, spacing: 2) {
                Text("Include Mail, Messages and iPhone backups")
                    .font(.callout.weight(.semibold))
                Text(permissions.isWaitingForFullDiskAccess
                     ? "Waiting for Full Disk Access. Drag Mac Vitals into the list in System Settings."
                     : "These are protected by macOS. Optional: turn on Full Disk Access and they'll be included automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if permissions.isWaitingForFullDiskAccess {
                ProgressView().controlSize(.small)
            } else {
                Button("Allow Access", action: request)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerStyle(.link)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.disk.opacity(0.08)))
    }
}

// MARK: - Largest files

private struct LargestFilesCard: View {
    @Environment(StorageModel.self) private var storage
    @State private var trashed: Set<String> = []
    @State private var pendingTrash: StorageItem?

    var body: some View {
        let files = (storage.report?.largestFiles ?? []).filter { !trashed.contains($0.id) }
        Card("Largest files", systemImage: "doc.badge.arrow.up", tint: Theme.disk) {
            if storage.report == nil {
                Text("Scan your storage to find the biggest individual files, like old videos, disk images and virtual machines.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if files.isEmpty {
                Text("No files over 200 MB in the folders Mac Vitals can see.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(files.prefix(8)) { file in
                        LargeFileRow(file: file) { pendingTrash = file }
                    }
                }
            }
        }
        .fillingHeight()
        .confirmationDialog(
            pendingTrash.map { "Move \($0.name) to the Trash?" } ?? "",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { file in
            Button("Move to Trash", role: .destructive) {
                if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)) != nil {
                    withAnimation(.spring) { _ = trashed.insert(file.id) }
                }
            }
        } message: { file in
            Text("\(Fmt.bytes(file.size)) will be freed when you empty the Trash.")
        }
    }
}

private struct LargeFileRow: View {
    let file: StorageItem
    let onTrash: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(parentFolder)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(Fmt.bytes(file.size)).font(.callout).monospacedDigit()
            HStack(spacing: 6) {
                Button { ProcessController.revealInFinder(file.path) } label: { Image(systemName: "magnifyingglass") }
                    .help("Reveal in Finder")
                Button(action: onTrash) { Image(systemName: "trash") }
                    .help("Move to Trash")
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }

    private var parentFolder: String {
        let parent = (file.path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }
}

// MARK: - Drive health

enum DriveHealth {
    /// The SSD's own S.M.A.R.T. status ("Verified" / "Failing"), via system_profiler.
    /// Takes ~1s, so it's fetched once per page visit off the main thread.
    static func status() async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPNVMeDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parseStatus(data)
        }.value
    }

    static func parseStatus(_ json: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let controllers = root["SPNVMeDataType"] as? [[String: Any]] else { return nil }
        for controller in controllers {
            for drive in controller["_items"] as? [[String: Any]] ?? [] {
                if let status = drive["smart_status"] as? String {
                    return status.lowercased() == "verified" ? "Verified" : status.capitalized
                }
            }
        }
        return nil
    }
}
