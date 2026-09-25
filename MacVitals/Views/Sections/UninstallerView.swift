import SwiftUI
import AppKit

/// Uninstaller: every app you installed, what it really costs (app + its data), when you last
/// opened it, and a clean uninstall that removes its leftovers too. Everything goes to the Trash
/// through the shared remover, so uninstalls can be put back.
struct UninstallerView: View {
    @Environment(UninstallerModel.self) private var model
    @Environment(CleanupEngine.self) private var engine
    @Environment(Router.self) private var router
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .size
    @State private var pendingUninstall: InstalledApp?

    enum Filter: String, CaseIterable, Identifiable {
        case all, unused
        var id: String { rawValue }
        var title: String { self == .all ? "All apps" : "Not used in 6 months" }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size, lastUsed, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: "Size"
            case .lastUsed: "Last opened"
            case .name: "Name"
            }
        }
    }

    private var visibleApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.apps
            .filter { filter == .all || $0.isUnused() }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                switch sort {
                case .size: a.totalSize > b.totalSize
                // Never-opened first, then oldest.
                case .lastUsed: (a.lastUsed ?? .distantPast) < (b.lastUsed ?? .distantPast)
                case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
    }

    var body: some View {
        SectionScroll {
            hero.entrance()
            stats.entrance(delay: 0.04)
            if let record = engine.lastRecord {
                CleanupResultBanner(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            leftoversCard.entrance(delay: 0.06)
            listCard.entrance(delay: 0.1)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .task { if model.phase == .idle { await model.scan() } }
        .onChange(of: engine.putBackCount) { Task { await model.scan() } }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: engine.lastRecord?.id)
        .sheet(item: $pendingUninstall) { app in
            UninstallSheet(app: app, isRunning: model.isRunning(app)) { items in
                Task { await model.uninstall(app, items: items, engine: engine) }
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        let unused = model.unusedApps
        let unusedSize = unused.reduce(Int64(0)) { $0 + $1.totalSize }
        let top = Array(unused.sorted { $0.totalSize > $1.totalSize }.prefix(3))
        return HStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.cleanup.opacity(0.12))
                if model.phase == .scanning && model.apps.isEmpty {
                    ProgressView(value: Double(model.inspected), total: Double(max(model.total, 1)))
                        .progressViewStyle(.circular)
                } else {
                    ForEach(Array(top.enumerated().reversed()), id: \.element.id) { index, app in
                        AppIconView(bundlePath: app.path, kind: .application, size: index == 0 ? 54 : 40)
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            .offset(x: index == 0 ? 0 : (index == 1 ? -30 : 30), y: index == 0 ? -4 : 16)
                    }
                    if top.isEmpty {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(.green)
                    }
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                if model.phase == .scanning && model.apps.isEmpty {
                    Text("Looking at your apps…").font(.title2.weight(.semibold))
                    Text("\(model.inspected) of \(model.total) checked: size, data they keep and when you last opened them.")
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                } else if unused.isEmpty {
                    Text("You use everything you have installed").font(.title2.weight(.semibold))
                    Text("Every app has been opened in the last 6 months. Nothing obvious to uninstall.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(unused.count) app\(unused.count == 1 ? "" : "s") you haven't opened in 6 months")
                        .font(.title2.weight(.semibold))
                    Text("Uninstalling them would free about \(Fmt.bytes(unusedSize)), including the data they keep in your Library.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show unused apps") { filter = .unused; sort = .size }
                        .buttonStyle(.glass)
                        .pointerStyle(.link)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: Theme.cleanup)
    }

    // MARK: Stats

    private var stats: some View {
        let unused = model.unusedApps
        let leftovers = engine.scans[.appLeftovers]
        return HStack(spacing: 16) {
            DetailStat(label: "Apps", term: "Installed", value: "\(model.apps.count)",
                       caption: "In Applications folders")
            DetailStat(label: "Space used", term: "App + data", value: Fmt.bytes(model.totalSize),
                       caption: "Apps plus the data they keep",
                       help: "Each app's size plus its caches, settings and data in your Library.")
            DetailStat(label: "Unused", term: "6+ months", value: "\(unused.count)",
                       tint: unused.isEmpty ? nil : .yellow,
                       caption: Fmt.bytes(unused.reduce(0) { $0 + $1.totalSize }),
                       help: "Not opened in six months, according to Spotlight.")
            DetailStat(label: "Leftovers", term: "Deleted apps",
                       value: leftovers.map { Fmt.bytes($0.totalSize) } ?? "—",
                       caption: leftovers.map { "From \($0.groups.count) deleted app\($0.groups.count == 1 ? "" : "s")" } ?? "Not scanned yet")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Leftovers from deleted apps

    private var leftoversCard: some View {
        let scan = engine.scans[.appLeftovers]
        return HStack(spacing: 14) {
            Image(systemName: "app.dashed").font(.title2).foregroundStyle(Theme.cleanup)
            VStack(alignment: .leading, spacing: 2) {
                Text("Leftovers from apps you already deleted").font(.headline)
                Text(scan.map { $0.totalSize > 0
                        ? "\(Fmt.bytes($0.totalSize)) of settings and data from \($0.groups.prefix(3).map(\.title).joined(separator: ", "))\($0.groups.count > 3 ? " and more" : "")."
                        : "None found. Deleted apps left nothing significant behind." }
                     ?? "Dragging an app to the Trash leaves its data behind. Scan to find it.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let scan, scan.totalSize > 0 {
                Button("Review") { router.section = .junk }
                    .buttonStyle(.glass).pointerStyle(.link)
            } else if scan == nil {
                Button("Scan") { Task { await engine.scan() } }
                    .buttonStyle(.glass).pointerStyle(.link)
                    .disabled(engine.phase == .scanning)
            }
        }
        .cardStyle(padding: 16)
    }

    // MARK: List

    private var listCard: some View {
        let apps = visibleApps
        return Card("Installed apps", systemImage: "square.grid.2x2", tint: Theme.cleanup) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().pointerStyle(.link)
                Spacer()
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize().pointerStyle(.link)
            }
            if apps.isEmpty && model.phase == .ready {
                Text(search.isEmpty ? "No apps here." : "No apps match \"\(search)\".")
                    .foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().padding(.leading, 52) }
                    AppUninstallRow(app: app, isRunning: model.isRunning(app)) { pendingUninstall = app }
                }
            }
        } accessory: {
            HStack(spacing: 8) {
                if model.phase == .scanning, !model.apps.isEmpty { ProgressView().controlSize(.small) }
                Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                    .help("Scan apps again")
                    .disabled(model.phase == .scanning)
            }
        }
    }
}

// MARK: - Row

private struct AppUninstallRow: View {
    let app: InstalledApp
    let isRunning: Bool
    let onUninstall: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(bundlePath: app.path, kind: .application, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                    if let version = app.version {
                        Text(version).font(.caption).foregroundStyle(.tertiary)
                    }
                    if app.isAppStore {
                        Text("App Store").font(.caption2.weight(.semibold)).glassChip()
                    }
                    if isRunning {
                        Label("Open", systemImage: "circle.fill").labelStyle(.titleAndIcon)
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
                Text(lastUsedText)
                    .font(.caption)
                    .foregroundStyle(app.isUnused() ? .orange : .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.bytes(app.totalSize)).font(.callout.weight(.semibold)).monospacedDigit()
                Text(app.dataSize > 0 ? "\(Fmt.bytes(app.appSize)) app · \(Fmt.bytes(app.dataSize)) data" : "app only")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Uninstall…", action: onUninstall)
                .buttonStyle(.glass)
                .controlSize(.small)
                .pointerStyle(.link)
                .opacity(hovering ? 1 : 0.55)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Uninstall \(app.name)…", action: onUninstall)
            Button("Reveal in Finder") { ProcessController.revealInFinder(app.path) }
        }
    }

    private var lastUsedText: String {
        guard let lastUsed = app.lastUsed else { return "No record of being opened" }
        let days = Date().timeIntervalSince(lastUsed) / 86_400
        if app.neverOpened { return "Never opened · installed \(JunkScanners.describeAge(days: days))" }
        return days < 1 ? "Opened today" : "Last opened \(JunkScanners.describeAge(days: days))"
    }
}

// MARK: - Uninstall sheet

/// Shows exactly what will be removed. Everything is pre-ticked; untick anything to keep it.
private struct UninstallSheet: View {
    let app: InstalledApp
    let isRunning: Bool
    let onConfirm: ([JunkItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(app: InstalledApp, isRunning: Bool, onConfirm: @escaping ([JunkItem]) -> Void) {
        self.app = app
        self.isRunning = isRunning
        self.onConfirm = onConfirm
        _selected = State(initialValue: Set([app.bundleItem.id] + app.leftovers.map(\.id)))
    }

    private var allItems: [JunkItem] { [app.bundleItem] + app.leftovers }
    private var chosen: [JunkItem] { allItems.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AppIconView(bundlePath: app.path, kind: .application, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uninstall \(app.name)?").font(.title2.weight(.semibold))
                    Text("Removes the app and the data it keeps in your Library. Everything goes to the Trash, so you can put it back from Smart Clean › Recent cleanups.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if isRunning {
                Label("\(app.name) is open. It'll be asked to quit first, so save any work.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            VStack(spacing: 0) {
                ForEach(Array(allItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { selected.contains(item.id) },
                            set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }
                        )) { EmptyView() }
                        .toggleStyle(.checkbox).labelsHidden().pointerStyle(.link)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.callout.weight(.medium))
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Text(Fmt.bytes(item.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            if app.leftovers.isEmpty {
                Text("No extra data found in your Library for this app.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(Fmt.bytes(chosen.reduce(0) { $0 + $1.size })) will be moved to the Trash")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerStyle(.link)
                Button(isRunning ? "Quit & Uninstall" : "Uninstall", role: .destructive) {
                    onConfirm(chosen)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .pointerStyle(.link)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
