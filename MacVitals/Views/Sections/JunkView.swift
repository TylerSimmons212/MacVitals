import SwiftUI
import AppKit

/// Junk: the full review. Every group says what it is and what happens if you remove it;
/// every item carries a safety tier. Only Safe items start selected.
struct JunkView: View {
    @Environment(CleanupEngine.self) private var engine
    @Environment(Permissions.self) private var permissions
    @AppStorage(SettingsKeys.cleanupDeletesPermanently) private var deletePermanently = false
    @State private var tierFilter: SafetyTier?
    @State private var expanded: Set<String> = []
    @State private var confirming = false

    var body: some View {
        ZStack(alignment: .bottom) {
            SectionScroll {
                header.entrance()
                if let record = engine.lastRecord {
                    CleanupResultBanner(record: record)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if engine.phase == .idle {
                    ContentUnavailableView {
                        Label("Nothing scanned yet", systemImage: "sparkle.magnifyingglass")
                    } description: {
                        Text("Scan to see caches, developer junk, old installers and more.")
                    } actions: {
                        Button("Scan") { Task { await engine.scan() } }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.cleanup)
                            .pointerStyle(.link)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .cardStyle()
                }
                ForEach(engine.orderedScans) { scan in
                    moduleSection(scan)
                        .transition(.push(from: .bottom).combined(with: .opacity))
                }
                Color.clear.frame(height: engine.phase == .ready && engine.totalFound > 0 ? 80 : 0)
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: engine.orderedScans.map(\.module))
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: engine.lastRecord?.id)

            if (engine.phase == .ready || engine.phase == .cleaning) && engine.totalFound > 0 {
                actionBar
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: engine.phase)
        .confirmationDialog("Clean \(Fmt.bytes(engine.selectedSize))?", isPresented: $confirming) {
            Button(deletePermanently || engine.selectionIncludesPermanent ? "Delete" : "Move to Trash", role: .destructive) {
                Task { await engine.clean(permanently: deletePermanently) }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.phase == .scanning ? "Scanning…" : "\(Fmt.bytes(engine.totalFound)) found")
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
                Text(engine.lastScan.map { "Scanned \($0.formatted(.relative(presentation: .named)))" } ?? "Review what can be removed, grouped by what it is.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Show", selection: $tierFilter) {
                Text("All").tag(SafetyTier?.none)
                ForEach(SafetyTier.allCases, id: \.self) { tier in
                    Text(tier.label).tag(Optional(tier))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .pointerStyle(.link)
            .help("Filter by how safe items are to remove")
            Button {
                Task { await engine.scan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .pointerStyle(.link)
            .disabled(engine.phase == .scanning || engine.phase == .cleaning)
        }
    }

    // MARK: Modules & groups

    private func moduleSection(_ scan: ModuleScan) -> some View {
        let groups = scan.groups.compactMap { filtered($0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: scan.module.icon).foregroundStyle(Theme.cleanup).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(scan.module.title).font(.headline)
                    Text(scan.module.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(scan.totalSize > 0 ? Fmt.bytes(scan.totalSize) : "Nothing to clean")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(scan.totalSize > 0 ? .primary : .secondary)
            }
            .padding(.top, 6)

            if scan.needsAccess {
                HStack(spacing: 10) {
                    Image(systemName: "lock").foregroundStyle(.orange)
                    Text("macOS blocked part of this scan. Allow Full Disk Access to include it.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow Access") {
                        permissions.onFullDiskAccessGranted = { Task { await engine.scan() } }
                        permissions.requestFullDiskAccess()
                    }
                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                }
                .cardStyle(padding: 12)
            }

            ForEach(groups) { group in
                JunkGroupCard(
                    group: group,
                    isExpanded: Binding(
                        get: { expanded.contains(group.id) },
                        set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } }
                    )
                )
            }
        }
    }

    private func filtered(_ group: JunkGroup) -> JunkGroup? {
        guard let tierFilter else { return group }
        let items = group.items.filter { $0.tier == tierFilter }
        guard !items.isEmpty else { return nil }
        return JunkGroup(id: group.id, title: group.title, icon: group.icon, explanation: group.explanation,
                         afterRemoval: group.afterRemoval, items: items, isPermanent: group.isPermanent)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Fmt.bytes(engine.selectedSize)) selected")
                    .font(.headline)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: engine.selectedSize)
                Text(deletePermanently ? "Will be deleted permanently" : "Goes to the Trash. You can put it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Delete immediately", isOn: $deletePermanently)
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointerStyle(.link)
                .help("Skip the Trash. Faster, but can't be undone.")
            Button {
                confirming = true
            } label: {
                Label("Clean", systemImage: "sparkles").padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.cleanup)
            .controlSize(.large)
            .pointerStyle(.link)
            .disabled(engine.selectedSize == 0 || engine.phase == .cleaning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .glassEffect(.regular.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }

    private var confirmMessage: String {
        let count = engine.selectedItems.count
        var parts = [deletePermanently
                     ? "\(count) items will be deleted permanently."
                     : "\(count) items will be moved to the Trash. You can put them back from Smart Clean › Recent cleanups."]
        if engine.selectionIncludesPermanent && !deletePermanently {
            parts.append("Items already in the Trash will be deleted permanently.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Group card

private struct JunkGroupCard: View {
    let group: JunkGroup
    @Binding var isExpanded: Bool
    @Environment(CleanupEngine.self) private var engine

    var body: some View {
        let selectedSize = engine.selectedSize(in: group)
        let fullySelected = engine.isSelected(group)
        let tiers = Set(group.items.map(\.tier)).sorted()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    withAnimation(.snappy) { engine.toggle(group) }
                } label: {
                    Image(systemName: fullySelected ? "checkmark.circle.fill" : selectedSize > 0 ? "minus.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedSize > 0 ? Theme.cleanup : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)

                Image(systemName: group.icon).font(.title3).foregroundStyle(Theme.cleanup).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.title).font(.body.weight(.semibold))
                        ForEach(tiers, id: \.self) { TierPill(tier: $0) }
                    }
                    Text(group.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Label(group.afterRemoval, systemImage: group.isPermanent ? "exclamationmark.triangle" : "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(group.isPermanent ? .orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.bytes(group.totalSize)).font(.body.weight(.semibold)).monospacedDigit()
                    Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(isExpanded ? "Hide items" : "Show items")
            }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.items.prefix(150)) { item in
                        JunkItemRow(item: item)
                    }
                    if group.items.count > 150 {
                        Text("+ \(group.items.count - 150) more").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }
                .padding(.leading, 38)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardStyle(padding: 14, tint: selectedSize > 0 ? Theme.cleanup : nil)
    }
}

private struct JunkItemRow: View {
    let item: JunkItem
    @Environment(CleanupEngine.self) private var engine
    @State private var hovering = false

    var body: some View {
        let isOn = Binding(
            get: { engine.selection.contains(item.id) },
            set: { _ in engine.toggle(item) }
        )
        HStack(spacing: 10) {
            Toggle(isOn: isOn) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .pointerStyle(.link)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer()
            TierPill(tier: item.tier)
            Text(Fmt.bytes(item.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Button {
                ProcessController.revealInFinder(item.path)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.35)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }
}
