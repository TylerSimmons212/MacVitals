import SwiftUI

/// Smart Clean: one scan across every Clean Up module, a one-click clean for the safe parts,
/// a card per area linking to the full review, and recent cleanups with Put Back.
struct SmartCleanView: View {
    @Environment(CleanupEngine.self) private var engine
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Router.self) private var router
    @Environment(\.motionEnabled) private var motionEnabled
    @State private var confirmingSafeClean = false

    var body: some View {
        SectionScroll {
            hero.entrance()
            if let record = engine.lastRecord {
                CleanupResultBanner(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            modules.entrance(delay: 0.06)
            if !engine.history.isEmpty {
                history.entrance(delay: 0.1)
            }
            principles.entrance(delay: 0.12)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: engine.phase)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: engine.lastRecord?.id)
        .confirmationDialog("Clean \(Fmt.bytes(engine.safeTotal)) of safe items?", isPresented: $confirmingSafeClean) {
            Button("Move to Trash") { Task { await engine.cleanSafeItems() } }
        } message: {
            Text("Only items marked Safe: caches, logs and build data that rebuild on their own. Everything goes to the Trash, and you can put it back.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 24) {
            ScanOrb(
                scanning: engine.phase == .scanning || engine.phase == .cleaning,
                progress: engine.phase == .scanning ? engine.scanProgress : (engine.phase == .idle ? 0 : 1),
                animated: motionEnabled
            )
            .frame(width: 128, height: 128)

            VStack(alignment: .leading, spacing: 6) {
                switch engine.phase {
                case .idle:
                    Text("Find junk you can safely remove").font(.title2.weight(.semibold))
                    Text("Scans caches, logs, developer build data, old project dependencies and forgotten installers. Nothing is removed until you say so.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await engine.scan() }
                    } label: {
                        Label("Scan", systemImage: "sparkle.magnifyingglass").padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.cleanup)
                    .controlSize(.large)
                    .pointerStyle(.link)
                    .padding(.top, 8)
                case .scanning:
                    Text("Scanning…").font(.title2.weight(.semibold))
                    Text("\(engine.scans.count) of \(CleanupModuleKind.allCases.count) areas checked. Developer folders can take a minute.")
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                case .cleaning:
                    Text("Cleaning…").font(.title2.weight(.semibold))
                    Text("Moving items to the Trash.").foregroundStyle(.secondary)
                case .ready:
                    readySummary
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 22, tint: Theme.cleanup)
    }

    @ViewBuilder
    private var readySummary: some View {
        if engine.totalFound == 0 {
            Text("Your Mac is tidy").font(.title2.weight(.semibold))
            Text("Nothing worth cleaning right now. \(Fmt.bytes(monitor.disk.availableCapacity)) free.")
                .foregroundStyle(.secondary)
            rescanButton.padding(.top, 8)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.bytes(engine.totalFound))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.cleanup.gradient)
                    .contentTransition(.numericText())
                Text("of junk found").font(.title3).foregroundStyle(.secondary)
            }
            Text(engine.safeTotal > 0
                 ? "\(Fmt.bytes(engine.safeTotal)) is safe to remove right now. The rest is worth a quick look first."
                 : "Nothing is automatically safe. Review what was found and pick what to remove.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if engine.safeTotal > 0 {
                    Button {
                        confirmingSafeClean = true
                    } label: {
                        Label("Clean safe items · \(Fmt.bytes(engine.safeTotal))", systemImage: "sparkles").padding(.horizontal, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.cleanup)
                    .controlSize(.large)
                    .pointerStyle(.link)
                }
                Button("Review everything") { router.section = .junk }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .pointerStyle(.link)
                rescanButton
            }
            .padding(.top, 8)
        }
    }

    private var rescanButton: some View {
        Button {
            Task { await engine.scan() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .pointerStyle(.link)
        .help("Scan again")
    }

    // MARK: Modules

    private var modules: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
            ForEach(CleanupModuleKind.allCases) { module in
                ModuleCard(module: module, scan: engine.scans[module], scanning: engine.scanning.contains(module)) {
                    router.section = .junk
                }
            }
        }
    }

    // MARK: History

    private var history: some View {
        Card("Recent cleanups", systemImage: "clock.arrow.circlepath", tint: Theme.cleanup) {
            VStack(spacing: 0) {
                ForEach(Array(engine.history.prefix(5).enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider() }
                    HistoryRow(record: record)
                }
            }
        }
    }

    // MARK: Principles

    private var principles: some View {
        HStack(spacing: 10) {
            principle("Trash first", "Nothing is deleted outright unless you ask.", "trash")
            principle("Put back anytime", "Every cleanup can be undone from Recent cleanups.", "arrow.uturn.backward")
            principle("macOS is off-limits", "System files are never touched.", "lock.shield")
        }
    }

    private func principle(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.cleanup).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 12)
    }
}

private struct ModuleCard: View {
    let module: CleanupModuleKind
    let scan: ModuleScan?
    let scanning: Bool
    let onReview: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onReview) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(module.title, systemImage: module.icon)
                        .font(.headline)
                        .labelStyle(TintedIconLabelStyle(tint: Theme.cleanup))
                    Spacer()
                    if scanning {
                        ProgressView().controlSize(.small)
                    } else if let scan {
                        Text(scan.totalSize > 0 ? Fmt.bytes(scan.totalSize) : "Clean")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(scan.totalSize > 0 ? .primary : .secondary)
                    }
                }
                Text(module.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let scan, scan.totalSize > 0 {
                    tierBar(scan)
                    VStack(spacing: 4) {
                        ForEach(scan.groups.sorted { $0.totalSize > $1.totalSize }.prefix(3)) { group in
                            HStack {
                                Text(group.title).font(.callout).lineLimit(1)
                                Spacer()
                                Text(Fmt.bytes(group.totalSize)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if scan?.needsAccess == true {
                    Label("Needs Full Disk Access to measure", systemImage: "lock").font(.caption).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .cardStyle(padding: 16, interactive: true, fillHeight: true)
            .scaleEffect(hovering ? 1.01 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hovering)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .disabled(scan == nil || scan?.totalSize == 0)
    }

    private func tierBar(_ scan: ModuleScan) -> some View {
        let sizes = SafetyTier.allCases.map { tier in
            (tier, scan.items.filter { $0.tier == tier }.reduce(Int64(0)) { $0 + $1.size })
        }.filter { $0.1 > 0 }
        return VStack(alignment: .leading, spacing: 4) {
            SegmentedBar(segments: sizes.map { .init(label: $0.0.label, value: Double($0.1), color: Theme.tier($0.0)) }, height: 8)
            HStack(spacing: 10) {
                ForEach(sizes, id: \.0) { tier, size in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.tier(tier)).frame(width: 6, height: 6)
                        Text("\(tier.label) \(Fmt.bytes(size))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let record: CleanupRecord
    @Environment(CleanupEngine.self) private var engine
    @State private var working = false

    var body: some View {
        let restorable = record.restorable
        HStack(spacing: 12) {
            Image(systemName: restorable.isEmpty ? "checkmark.circle" : "trash.circle")
                .foregroundStyle(restorable.isEmpty ? Color.secondary : Theme.cleanup)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Fmt.bytes(record.total)) · \(record.entries.count) item\(record.entries.count == 1 ? "" : "s")")
                    .font(.callout.weight(.medium))
                Text(record.date.formatted(.relative(presentation: .named)) + " · " + statusText(restorable: restorable))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            if !restorable.isEmpty {
                Button("Put Back") {
                    working = true
                    Task { await engine.putBack(record); working = false }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .pointerStyle(.link)
                .help("Move \(restorable.count) item\(restorable.count == 1 ? "" : "s") from the Trash back to where they were")
            }
        }
        .padding(.vertical, 8)
    }

    private func statusText(restorable: [CleanupRecord.Entry]) -> String {
        if restorable.count == record.entries.count { return "In the Trash, can be put back" }
        if !restorable.isEmpty { return "\(restorable.count) still in the Trash" }
        return record.movedToTrash > 0 ? "Trash emptied or restored" : "Deleted permanently"
    }
}
