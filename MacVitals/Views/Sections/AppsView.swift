import SwiftUI

/// Apps page. For everyone: what's open, what's heavy (one plain impact rating instead of five
/// columns), what anything unfamiliar *is*, and which apps are misbehaving. Under the hood: the
/// full Activity Monitor–style table.
struct AppsView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var search = ""
    @State private var filter: Filter = .apps
    @State private var sort: SortKey = .impact
    @AppStorage("appsShowDetailed") private var showDetailed = false
    @State private var pendingQuit: PendingQuit?

    enum Filter: String, CaseIterable, Identifiable {
        case apps, background, system, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apps: "Apps"
            case .background: "Background"
            case .system: "macOS"
            case .all: "All"
            }
        }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case impact, cpu, memory, energy, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .impact: "Impact"
            case .cpu: "CPU"
            case .memory: "Memory"
            case .energy: "Energy"
            case .name: "Name"
            }
        }
    }

    struct PendingQuit: Identifiable {
        let app: AppUsage?
        let pid: pid_t?
        let name: String
        let force: Bool
        var id: String { "\(name)-\(force)" }
    }

    private var cores: Int { max(monitor.cpu.perCore.count, monitor.info.logicalCores) }

    var body: some View {
        let policies = AppInsights.activationPolicies()
        let roles = Dictionary(uniqueKeysWithValues: monitor.apps.map { ($0.id, AppInsights.role(for: $0, policies: policies)) })
        SectionScroll {
            verdict(roles: roles).entrance()
            stats(roles: roles).entrance(delay: 0.04)
            if !flaggedApps.isEmpty {
                needsAttention.entrance(delay: 0.06)
            }
            listCard(roles: roles).entrance(delay: 0.1)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps & processes")
        .confirmationDialog(
            pendingQuit.map { $0.force ? "Force quit \($0.name)?" : "Quit \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            presenting: pendingQuit
        ) { pending in
            Button(pending.force ? "Force Quit" : "Quit", role: pending.force ? .destructive : nil) {
                if let app = pending.app {
                    ProcessController.quit(app, force: pending.force)
                } else if let pid = pending.pid {
                    ProcessController.signal(pid, force: pending.force)
                }
            }
        } message: { pending in
            Text(pending.force ? "Unsaved changes will be lost." : "The app will be asked to quit normally, so it can save your work.")
        }
    }

    // MARK: Derived data

    private var flaggedApps: [(app: AppUsage, flags: [AppInsights.Flag])] {
        monitor.apps.compactMap { app in
            guard !app.isCurrentApp, let flags = monitor.appFlags[app.id], !flags.isEmpty else { return nil }
            return (app, flags)
        }
    }

    private func score(_ app: AppUsage) -> Double {
        AppInsights.impactScore(app, cores: cores, totalRAM: monitor.memory.total)
    }

    private func visibleApps(roles: [String: AppInsights.Role]) -> [AppUsage] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = monitor.apps.filter { app in
            let role = roles[app.id] ?? .background
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .apps: role == .app
            case .background: role == .background
            case .system: role == .system
            }
            guard matchesFilter || !query.isEmpty else { return false }
            guard !query.isEmpty else { return true }
            return app.name.localizedCaseInsensitiveContains(query)
                || app.processes.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return filtered.sorted { a, b in
            switch sort {
            case .impact: score(a) > score(b)
            case .cpu: a.cpu > b.cpu
            case .memory: a.memory > b.memory
            case .energy: a.watts > b.watts
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: Verdict

    private func verdict(roles: [String: AppInsights.Role]) -> some View {
        let appCount = roles.values.filter { $0 == .app }.count
        let flagged = flaggedApps
        let heaviest = monitor.apps.filter { !$0.isCurrentApp }.sorted { score($0) > score($1) }
        let top = Array(heaviest.prefix(3))
        let tint: Color = flagged.isEmpty ? .green : .orange

        let title: String = switch flagged.count {
        case 0: "\(appCount) apps open · everything's behaving"
        case 1: "\(flagged[0].app.name) needs attention"
        default: "\(flagged.count) apps need attention"
        }
        let sentence: String = {
            if let first = flagged.first, let flag = first.flags.first { return flag.detail }
            if let heavy = heaviest.first, AppInsights.impact(score: score(heavy)) != .low {
                return "Nothing is stuck or leaking memory. \(heavy.name) is the heaviest right now."
            }
            return "Nothing is stuck or leaking memory, and nothing is working especially hard."
        }()

        return HStack(spacing: 22) {
            // The three heaviest apps, fanned out.
            ZStack {
                Circle().fill(tint.opacity(0.12))
                ForEach(Array(top.enumerated().reversed()), id: \.element.id) { index, app in
                    AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: index == 0 ? 52 : 38)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .offset(x: index == 0 ? 0 : (index == 1 ? -30 : 30), y: index == 0 ? -4 : 16)
                        .opacity(index == 0 ? 1 : 0.85)
                }
            }
            .frame(width: 112, height: 112)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: top.map(\.id))

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.interpolate)
                Text(sentence)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    // MARK: Stats

    private func stats(roles: [String: AppInsights.Role]) -> some View {
        let appCount = roles.values.filter { $0 == .app }.count
        let backgroundCount = roles.values.filter { $0 == .background }.count
        let processCount = monitor.apps.reduce(0) { $0 + $1.processCount }
        let heaviest = monitor.apps.filter { !$0.isCurrentApp }.max { score($0) < score($1) }
        return HStack(spacing: 16) {
            DetailStat(label: "Apps open", term: "Foreground",
                       value: "\(appCount)",
                       caption: "Apps with windows in your Dock",
                       rolls: true)
            DetailStat(label: "Background", term: "Agents",
                       value: "\(backgroundCount)",
                       caption: "Menu bar apps, helpers and services",
                       help: "Programs running without a Dock icon: menu bar utilities, updaters, sync tools and developer tools.",
                       rolls: true)
            DetailStat(label: "Processes", term: "PIDs",
                       value: "\(processCount)",
                       caption: "Apps often run several at once",
                       help: "Browsers and many apps split work into separate processes (one per tab, extension or helper). Mac Vitals groups them under their app.")
            DetailStat(label: "Heaviest", term: "Impact",
                       value: heaviest?.name ?? "—",
                       caption: heaviest.map { AppInsights.impact(score: score($0)).label } ?? "")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Needs attention

    private var needsAttention: some View {
        Card("Needs attention", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
            VStack(spacing: 12) {
                ForEach(flaggedApps, id: \.app.id) { item in
                    HStack(alignment: .top, spacing: 12) {
                        AppIconView(bundlePath: item.app.bundlePath, kind: item.app.kind, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.app.name).font(.body.weight(.semibold))
                            ForEach(Array(item.flags.enumerated()), id: \.offset) { _, flag in
                                Text(flag.title).font(.callout.weight(.medium)).foregroundStyle(.orange)
                                Text(flag.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        if ProcessController.canQuit(item.app) {
                            Button("Quit") {
                                pendingQuit = PendingQuit(app: item.app, pid: nil, name: item.app.name, force: false)
                            }
                            .buttonStyle(.glass)
                            .pointerStyle(.link)
                            if item.flags.contains(where: { if case .stuckBusy = $0 { true } else { false } }) {
                                Button("Force Quit") {
                                    pendingQuit = PendingQuit(app: item.app, pid: nil, name: item.app.name, force: true)
                                }
                                .buttonStyle(.glass)
                                .tint(.red)
                                .pointerStyle(.link)
                                .help("Use if the app won't quit normally")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: List

    private func listCard(roles: [String: AppInsights.Role]) -> some View {
        let apps = visibleApps(roles: roles)
        return Card(showDetailed ? "All processes" : "What's running", systemImage: "square.stack.3d.up", tint: Theme.cpu) {
            if !showDetailed {
                HStack(spacing: 10) {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .pointerStyle(.link)
                    Spacer()
                    Picker("Sort by", selection: $sort) {
                        ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .pointerStyle(.link)
                }
                if apps.isEmpty {
                    Text(search.isEmpty ? "Nothing here right now." : "No matches for \"\(search)\".")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                }
                LazyVStack(spacing: 2) {
                    ForEach(apps) { app in
                        AppRow(
                            app: app,
                            role: roles[app.id] ?? .background,
                            impact: AppInsights.impact(score: score(app)),
                            cpuShare: app.cpu / Double(cores),
                            flagged: !(monitor.appFlags[app.id] ?? []).isEmpty,
                            onQuit: { force in pendingQuit = PendingQuit(app: app, pid: nil, name: app.name, force: force) },
                            onQuitProcess: { process, force in
                                pendingQuit = PendingQuit(app: nil, pid: process.pid, name: process.name, force: force)
                            }
                        )
                    }
                }
            } else {
                DetailedAppsTable(apps: monitor.apps, search: search) { pending in pendingQuit = pending }
                    .frame(height: 560)
            }
        } accessory: {
            Picker("View", selection: $showDetailed) {
                Text("Simple").tag(false)
                Text("Detailed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .pointerStyle(.link)
            .help("Detailed shows every process with CPU, memory, disk and energy, like Activity Monitor")
        }
    }
}

// MARK: - Simple row

private struct AppRow: View {
    let app: AppUsage
    let role: AppInsights.Role
    let impact: AppInsights.Impact
    let cpuShare: Double
    let flagged: Bool
    let onQuit: (Bool) -> Void
    let onQuitProcess: (ProcessUsage, Bool) -> Void
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .opacity(app.processCount > 1 || explanation != nil ? 1 : 0)
                .disabled(app.processCount <= 1 && explanation == nil)

                AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                        if app.isCurrentApp { ThisAppBadge() }
                        if flagged {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                                .help("Needs attention. See the card above.")
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                metric(Fmt.percent(cpuShare, digits: cpuShare < 10 ? 1 : 0), "CPU")
                metric(Fmt.memory(app.memory), "Memory")
                metric(app.watts >= 0.05 ? String(format: "%.1f W", app.watts) : "—", "Energy")
                ImpactPill(impact: impact)
                    .frame(width: 92, alignment: .trailing)
                Button {
                    onQuit(false)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Quit \(app.name)")
                .opacity(hovering && ProcessController.canQuit(app) ? 1 : 0)
                .disabled(!ProcessController.canQuit(app))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .contextMenu {
                if ProcessController.canQuit(app) {
                    Button("Quit \(app.name)") { onQuit(false) }
                    Button("Force Quit \(app.name)") { onQuit(true) }
                }
                if let path = app.bundlePath {
                    Divider()
                    Button("Reveal in Finder") { ProcessController.revealInFinder(path) }
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let explanation, app.processCount <= 1 {
                        Text(explanation).font(.caption).foregroundStyle(.secondary).padding(.leading, 62)
                    }
                    if app.processCount > 1 {
                        ForEach(app.processes.sorted { $0.cpu > $1.cpu }.prefix(25)) { process in
                            ProcessRow(process: process, onQuit: { force in onQuitProcess(process, force) })
                        }
                        if app.processCount > 25 {
                            Text("+ \(app.processCount - 25) more. Switch to Detailed to see all.")
                                .font(.caption).foregroundStyle(.tertiary).padding(.leading, 62)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var explanation: String? {
        guard app.processCount == 1, let name = app.processes.first?.name,
              let entry = ProcessGlossary.explain(name) else { return nil }
        return [entry.what, entry.busyAdvice].compactMap { $0 }.joined(separator: " ")
    }

    private var subtitle: String {
        if role == .system { return "Parts of macOS · \(app.processCount) processes · Safe to ignore" }
        if app.processCount == 1, let name = app.processes.first?.name, let entry = ProcessGlossary.explain(name) {
            return entry.what
        }
        let kind = role == .app ? "App" : "Background"
        return app.processCount > 1 ? "\(kind) · \(app.processCount) processes" : kind
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.callout).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(width: 70, alignment: .trailing)
    }
}

private struct ProcessRow: View {
    let process: ProcessUsage
    let onQuit: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let entry = ProcessGlossary.explain(process.name)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if let entry {
                    Text(entry.what).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help([entry.what, entry.busyAdvice].compactMap { $0 }.joined(separator: " "))
                }
            }
            Spacer()
            Text(Fmt.percent(process.cpu, digits: 1)).font(.caption).monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(Fmt.memory(process.memory)).font(.caption).monospacedDigit().frame(width: 70, alignment: .trailing)
            Text(verbatim: "PID \(process.pid)").font(.caption2).monospacedDigit().foregroundStyle(.tertiary).frame(width: 70, alignment: .trailing)
            Button { onQuit(false) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Quit this process")
        }
        .padding(.vertical, 3)
        .padding(.leading, 62)
        .padding(.trailing, 8)
        .onHover { hovering = $0 }
    }
}

private struct ImpactPill: View {
    let impact: AppInsights.Impact

    var body: some View {
        Text(impact.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(impact == .low ? 0.08 : 0.16), in: Capsule())
            .foregroundStyle(impact == .low ? .secondary : color)
            .help("Combines CPU, memory and energy use into one rating.")
    }

    private var color: Color {
        switch impact {
        case .high: .orange
        case .medium: .yellow
        case .low: .gray
        }
    }
}

// MARK: - Detailed table (Activity Monitor style)

/// Table row: either an app group (with child processes) or a single process.
struct UsageRow: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String?
    let kind: AppKind
    let pid: pid_t?
    let processCount: Int
    let cpu: Double
    let memory: UInt64
    let diskRead: Double
    let diskWrite: Double
    let watts: Double
    var children: [UsageRow]?

    init(app: AppUsage) {
        id = app.id
        name = app.name
        bundlePath = app.bundlePath
        kind = app.kind
        pid = app.processCount == 1 ? app.processes.first?.pid : nil
        processCount = app.processCount
        cpu = app.cpu
        memory = app.memory
        diskRead = app.diskReadRate
        diskWrite = app.diskWriteRate
        watts = app.watts
        children = app.processCount > 1 ? app.processes.map(UsageRow.init(process:)) : nil
    }

    init(process: ProcessUsage) {
        id = "pid:\(process.pid)"
        name = process.name
        bundlePath = nil
        kind = .process
        pid = process.pid
        processCount = 1
        cpu = process.cpu
        memory = process.memory
        diskRead = process.diskReadRate
        diskWrite = process.diskWriteRate
        watts = process.watts
        children = nil
    }

    var pidSort: Int { Int(pid ?? 0) }
}

private struct DetailedAppsTable: View {
    let apps: [AppUsage]
    let search: String
    let onQuit: (AppsView.PendingQuit) -> Void
    @State private var sortOrder = [KeyPathComparator(\UsageRow.cpu, order: .reverse)]
    @State private var selection: UsageRow.ID?

    private var rows: [UsageRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? apps : apps.filter { app in
            app.name.localizedCaseInsensitiveContains(query)
                || app.processes.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return filtered.map(UsageRow.init(app:)).sorted(using: sortOrder).map { row in
            var row = row
            row.children = row.children?.sorted(using: sortOrder)
            return row
        }
    }

    var body: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) {
                    AppIconView(bundlePath: row.bundlePath, kind: row.kind, size: 18)
                    Text(row.name).lineLimit(1)
                    if row.children != nil {
                        Text("\(row.processCount)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .help(ProcessGlossary.explain(row.name)?.what ?? row.name)
            }
            .width(min: 220, ideal: 300)

            TableColumn("% CPU", value: \.cpu) { row in
                Text(Fmt.percent(row.cpu, digits: 1))
                    .monospacedDigit()
                    .foregroundStyle(row.cpu > 80 ? .red : row.cpu > 30 ? .orange : .primary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Memory", value: \.memory) { row in
                Text(Fmt.memory(row.memory)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Energy", value: \.watts) { row in
                Text(row.watts >= 0.01 ? String(format: "%.2f W", row.watts) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Disk Read", value: \.diskRead) { row in
                Text(Fmt.rate(row.diskRead)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Disk Write", value: \.diskWrite) { row in
                Text(Fmt.rate(row.diskWrite)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("PID", value: \.pidSort) { row in
                Text(row.pid.map(String.init) ?? "").monospacedDigit().foregroundStyle(.tertiary)
            }
            .width(min: 50, ideal: 60)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UsageRow.ID.self) { ids in
            if let id = ids.first { menu(for: id) }
        }
    }

    @ViewBuilder
    private func menu(for id: String) -> some View {
        if id.hasPrefix("pid:"), let pid = pid_t(id.dropFirst(4)) {
            let process = apps.lazy.flatMap(\.processes).first { $0.pid == pid }
            let name = process?.name ?? "process \(pid)"
            Button("Quit Process") { onQuit(.init(app: nil, pid: pid, name: name, force: false)) }
            Button("Force Quit Process") { onQuit(.init(app: nil, pid: pid, name: name, force: true)) }
            if let path = process?.path, !path.isEmpty {
                Divider()
                Button("Reveal in Finder") { ProcessController.revealInFinder(path) }
            }
        } else if let app = apps.first(where: { $0.id == id }) {
            Button("Quit \(app.name)") { onQuit(.init(app: app, pid: nil, name: app.name, force: false)) }
                .disabled(!ProcessController.canQuit(app))
            Button("Force Quit \(app.name)") { onQuit(.init(app: app, pid: nil, name: app.name, force: true)) }
                .disabled(!ProcessController.canQuit(app))
            if let bundlePath = app.bundlePath {
                Divider()
                Button("Reveal in Finder") { ProcessController.revealInFinder(bundlePath) }
            }
        }
    }
}
