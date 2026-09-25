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

    var broken: [StartupItem] { items.filter(\.isBroken) }
    func items(of kind: StartupItem.Kind) -> [StartupItem] { items.filter { $0.kind == kind && !$0.isBroken } }

    static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    func scan() async {
        guard phase != .scanning else { return }
        if items.isEmpty { phase = .scanning }
        items = await Task.detached(priority: .userInitiated) { StartupInventory.scan() }.value
        phase = .ready
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
    func remove(_ item: StartupItem, engine: CleanupEngine) async {
        guard item.isUserManageable, let plist = item.plistPath else { return }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        let record = await Task.detached(priority: .userInitiated) { () -> CleanupRecord in
            _ = LaunchctlController.turnOff(item)
            let size = (try? FileManager.default.attributesOfItem(atPath: plist)[.size] as? Int64) ?? 0
            return CleanupRemover.remove([JunkItem(path: plist, name: "\(item.name) (startup item)",
                                                   detail: plist, size: size, tier: .safe)], permanently: false)
        }.value
        engine.record(record)
        await scan()
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.loginItemsSettings)
    }
}
