import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class StartupModel {
    enum Phase: Equatable { case idle, scanning, ready }

    private(set) var phase: Phase = .idle
    private(set) var items: [StartupItem] = []
    private(set) var busy: Set<String> = []
    /// Whether the list includes everything macOS tracks (needs your password once per session).
    private(set) var isComplete = StartupInventory.isComplete
    private(set) var isUnlocking = false

    var broken: [StartupItem] { items.filter(\.isBroken) }
    func items(of kind: StartupItem.Kind) -> [StartupItem] { items.filter { $0.kind == kind && !$0.isBroken } }

    static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    func scan() async {
        guard phase != .scanning else { return }
        if items.isEmpty { phase = .scanning }
        items = await Task.detached(priority: .userInitiated) { StartupInventory.scan() }.value
        isComplete = StartupInventory.isComplete
        phase = .ready
    }

    /// Reads macOS's complete list after asking for your password (Mac Vitals' own prompt).
    func loadCompleteList() async {
        guard !isUnlocking else { return }
        isUnlocking = true
        // Let the "Waiting for your password" state render before the prompt takes over.
        try? await Task.sleep(for: .milliseconds(150))
        let unlocked = BTMAccess.readWithPassword()
        isUnlocking = false
        if unlocked { await scan() }
    }

    /// Reversible off/on for your own background helpers.
    func setEnabled(_ item: StartupItem, _ enabled: Bool) async {
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        _ = await Task.detached(priority: .userInitiated) {
            enabled ? LaunchctlController.turnOn(item) : LaunchctlController.turnOff(item)
        }.value
        await scan()
    }

    /// Removes a broken helper's plist via the Trash (so it can be put back), after stopping it.
    /// Items installed for all users come back as "needs your password", and the result
    /// banner finishes them through Finder.
    func remove(_ item: StartupItem, engine: CleanupEngine) async {
        guard let plist = item.plistPath else { return }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        let record = await Task.detached(priority: .userInitiated) { () -> CleanupRecord in
            if item.isUserManageable { _ = LaunchctlController.turnOff(item) }
            let size = (try? FileManager.default.attributesOfItem(atPath: plist)[.size] as? Int64) ?? 0
            return CleanupRemover.remove([JunkItem(path: plist, name: "\(item.name) (startup item)",
                                                   detail: plist, size: size, tier: .safe)], permanently: false)
        }.value
        engine.record(record)
        await scan()
    }

    /// System-wide items (in /Library): Finder moves them to the Trash after your password.
    func removeWithFinder(_ item: StartupItem, engine: CleanupEngine) async {
        guard let plist = item.plistPath else { return }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        let size = (try? FileManager.default.attributesOfItem(atPath: plist)[.size] as? Int64) ?? 0
        await engine.removeWithFinder([JunkItem(path: plist, name: "\(item.name) (startup item)", detail: plist, size: size, tier: .safe)])
        await scan()
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.loginItemsSettings)
    }
}
