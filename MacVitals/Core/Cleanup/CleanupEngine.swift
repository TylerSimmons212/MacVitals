import Foundation
import Observation

/// App-wide Clean Up state: runs every module's scanner in parallel, tracks selection
/// (safe items pre-selected), performs cleanups through `CleanupRemover`, and keeps history.
@MainActor
@Observable
final class CleanupEngine {
    enum Phase: Equatable {
        case idle, scanning, ready, cleaning
    }

    private(set) var phase: Phase = .idle
    private(set) var scans: [CleanupModuleKind: ModuleScan] = [:]
    private(set) var scanning: Set<CleanupModuleKind> = []
    private(set) var lastScan: Date?
    private(set) var history: [CleanupRecord] = CleanupHistoryStore.load()
    /// The cleanup that just finished, for the result banner.
    private(set) var lastRecord: CleanupRecord?
    var selection: Set<String> = []
    /// Bumped whenever something is put back, so other screens (Uninstaller) can refresh.
    private(set) var putBackCount = 0

    // MARK: Derived

    var orderedScans: [ModuleScan] { CleanupModuleKind.allCases.compactMap { scans[$0] } }
    var allItems: [JunkItem] { orderedScans.flatMap(\.items) }
    var totalFound: Int64 { orderedScans.reduce(0) { $0 + $1.totalSize } }
    var safeTotal: Int64 { orderedScans.reduce(0) { $0 + $1.safeSize } }
    var selectedItems: [JunkItem] { allItems.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var scanProgress: Double { Double(scans.count) / Double(CleanupModuleKind.allCases.count) }

    /// Items in the Trash module are deleted permanently when cleaned (that's what emptying means).
    private var permanentIDs: Set<String> {
        Set(orderedScans.flatMap(\.groups).filter(\.isPermanent).flatMap(\.items).map(\.id))
    }

    var selectionIncludesPermanent: Bool { !permanentIDs.isDisjoint(with: selection) }

    // MARK: Scan

    func scan() async {
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        scans = [:]
        selection = []
        scanning = Set(CleanupModuleKind.allCases)
        await withTaskGroup(of: ModuleScan.self) { group in
            for module in CleanupModuleKind.allCases {
                group.addTask(priority: .userInitiated) { JunkScanners.scan(module) }
            }
            for await result in group {
                scans[result.module] = result
                scanning.remove(result.module)
                // Only "safe" items start selected; everything else is opt-in.
                selection.formUnion(result.items.filter { $0.tier == .safe }.map(\.id))
            }
        }
        lastScan = Date()
        phase = .ready
    }

    // MARK: Clean

    func clean(permanently: Bool) async {
        await clean(selectedItems, permanently: permanently)
    }

    func cleanSafeItems() async {
        await clean(allItems.filter { $0.tier == .safe }, permanently: false)
    }

    private func clean(_ items: [JunkItem], permanently: Bool) async {
        guard !items.isEmpty, phase == .ready else { return }
        phase = .cleaning
        let permanent = permanentIDs
        let record = await Task.detached(priority: .userInitiated) {
            CleanupRemover.remove(items, permanently: permanently, permanentIDs: permanent)
        }.value
        remember(record)
        lastRecord = record
        phase = .ready
        await scan()
    }

    /// Empty just what the last cleanup moved to the Trash, so the space is actually freed.
    func finalize(_ record: CleanupRecord) async {
        let updated = await Task.detached(priority: .userInitiated) { CleanupRemover.finalize(record) }.value
        replace(updated)
        if lastRecord?.id == updated.id { lastRecord = updated }
    }

    func putBack(_ record: CleanupRecord) async {
        _ = await Task.detached(priority: .userInitiated) { CleanupRemover.putBack(record) }.value
        if lastRecord?.id == record.id { lastRecord = nil }
        putBackCount &+= 1
        history = history.map { $0 } // restorable state is computed from disk; nudge observers
        await scan()
    }

    func dismissResult() {
        lastRecord = nil
    }

    /// For removals done outside the Junk flow (e.g. uninstalling an app), so they get the same
    /// history, Put Back and Empty Now.
    func record(_ record: CleanupRecord) {
        remember(record)
        lastRecord = record
    }

    private func remember(_ record: CleanupRecord) {
        guard !record.entries.isEmpty else { return }
        history.insert(record, at: 0)
        CleanupHistoryStore.save(history)
    }

    private func replace(_ record: CleanupRecord) {
        if let index = history.firstIndex(where: { $0.id == record.id }) {
            history[index] = record
            CleanupHistoryStore.save(history)
        }
    }

    // MARK: Selection helpers

    func isSelected(_ group: JunkGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy { selection.contains($0.id) }
    }

    func selectedSize(in group: JunkGroup) -> Int64 {
        group.items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func toggle(_ group: JunkGroup) {
        let ids = Set(group.items.map(\.id))
        if isSelected(group) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggle(_ item: JunkItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }
}
