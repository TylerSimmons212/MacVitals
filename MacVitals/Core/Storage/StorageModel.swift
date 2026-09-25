import Foundation
import Observation

/// Owns the "What's taking up space" scan. Results are cached on disk and refreshed at most
/// daily (a full scan takes a minute or so), or whenever the user asks.
@MainActor
@Observable
final class StorageModel {
    enum Phase: Equatable {
        case idle, scanning, ready
    }

    private(set) var phase: Phase
    private(set) var report: StorageReport?
    private(set) var finishedKinds: Set<StorageKind> = []

    /// The user has seen our explanation and started a scan at least once.
    /// Before that, we explain what macOS is about to ask for instead of scanning.
    var hasConsented: Bool {
        get { UserDefaults.standard.bool(forKey: "storageScanConsented") }
        set { UserDefaults.standard.set(newValue, forKey: "storageScanConsented") }
    }

    init() {
        let cached = StorageScanner.loadCached()
        report = cached
        phase = cached == nil ? .idle : .ready
    }

    var progress: Double { Double(finishedKinds.count) / Double(StorageKind.allCases.count) }

    var isStale: Bool {
        guard let report else { return true }
        return Date().timeIntervalSince(report.scannedAt) > 86_400
    }

    var needsFullDiskAccess: Bool {
        report?.categories.contains { $0.kind.needsFullDiskAccess && $0.needsAccess } ?? false
    }

    var needsFolderAccess: Bool {
        report?.categories.contains { !$0.kind.needsFullDiskAccess && $0.needsAccess } ?? false
    }

    /// Refresh quietly in the background if the cached result is old. Only after consent,
    /// so the first-ever scan (and its privacy prompts) is always user-initiated.
    func refreshIfStale() async {
        guard hasConsented, isStale, phase != .scanning else { return }
        await scan()
    }

    func scan() async {
        guard phase != .scanning else { return }
        hasConsented = true
        phase = .scanning
        finishedKinds = []

        var categories: [StorageCategory] = []
        var bigFiles = TopItems(limit: StorageScanner.largestFileCount)
        // Categories are independent folder trees; scanning them in parallel is much faster on an SSD.
        await withTaskGroup(of: StorageScanner.Result.self) { group in
            for kind in StorageKind.allCases {
                group.addTask(priority: .utility) { StorageScanner.scan(kind) }
            }
            for await result in group {
                categories.append(result.category)
                bigFiles.merge(result.bigFiles)
                finishedKinds.insert(result.category.kind)
            }
        }

        let ordered = StorageKind.allCases.compactMap { kind in categories.first { $0.kind == kind } }
        let newReport = StorageReport(scannedAt: Date(), categories: ordered, largestFiles: bigFiles.items)
        report = newReport
        phase = .ready
        StorageScanner.save(newReport)
    }
}
