import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class UninstallerModel {
    enum Phase: Equatable { case idle, scanning, ready }

    private(set) var phase: Phase = .idle
    private(set) var apps: [InstalledApp] = []
    private(set) var inspected = 0
    private(set) var total = 0
    private(set) var lastScan: Date?

    var unusedApps: [InstalledApp] { apps.filter { $0.isUnused() } }
    var totalSize: Int64 { apps.reduce(0) { $0 + $1.totalSize } }

    /// Looks at every app (size, leftovers, last opened) in parallel.
    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        let bundles = await Task.detached(priority: .userInitiated) { AppInventory.appBundles() }.value
        total = bundles.count
        inspected = 0
        var found: [InstalledApp] = []
        await withTaskGroup(of: InstalledApp.self) { group in
            // A handful at a time: sizing app bundles is disk-heavy.
            var iterator = bundles.makeIterator()
            for _ in 0..<6 {
                if let url = iterator.next() { group.addTask(priority: .userInitiated) { AppInventory.inspect(url) } }
            }
            for await app in group {
                found.append(app)
                inspected += 1
                if let url = iterator.next() { group.addTask(priority: .userInitiated) { AppInventory.inspect(url) } }
            }
        }
        apps = Self.removingSharedLeftovers(found).sorted { $0.totalSize > $1.totalSize }
        lastScan = Date()
        phase = .ready
    }

    /// Safety net: if two installed apps both claim the same Library folder, it's shared (or a
    /// mis-match), so neither app's uninstall should remove it.
    nonisolated static func removingSharedLeftovers(_ apps: [InstalledApp]) -> [InstalledApp] {
        var claims: [String: Int] = [:]
        for app in apps { for item in app.leftovers { claims[item.path.lowercased(), default: 0] += 1 } }
        return apps.map { app in
            InstalledApp(path: app.path, name: app.name, bundleID: app.bundleID, version: app.version,
                         appSize: app.appSize,
                         leftovers: app.leftovers.filter { claims[$0.path.lowercased()] == 1 },
                         lastUsed: app.lastUsed, neverOpened: app.neverOpened, isAppStore: app.isAppStore)
        }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == app.path }
    }

    /// Quits the app if needed, then moves the chosen items to the Trash through the shared remover.
    func uninstall(_ app: InstalledApp, items: [JunkItem], engine: CleanupEngine) async {
        for running in NSWorkspace.shared.runningApplications where running.bundleURL?.path == app.path {
            running.terminate()
        }
        // Give it a moment to quit cleanly before moving it.
        for _ in 0..<20 where isRunning(app) { try? await Task.sleep(for: .milliseconds(250)) }
        let record = await Task.detached(priority: .userInitiated) {
            CleanupRemover.remove(items, permanently: false)
        }.value
        engine.record(record)
        if !FileManager.default.fileExists(atPath: app.path) {
            apps.removeAll { $0.id == app.id }
        }
    }
}
