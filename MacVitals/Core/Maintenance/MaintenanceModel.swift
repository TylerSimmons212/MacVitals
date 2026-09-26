import Foundation
import Observation

@MainActor
@Observable
final class MaintenanceModel {
    enum State: Equatable {
        case idle
        case running
        case done(Date)
        case failed(String)
    }

    private(set) var states: [MaintenanceTask.ID: State] = [:]
    private(set) var snapshots: [String] = []
    private(set) var snapshotsChecked = false

    func state(_ id: MaintenanceTask.ID) -> State { states[id] ?? .idle }

    /// When each task last ran successfully (kept across launches).
    func lastRun(_ id: MaintenanceTask.ID) -> Date? {
        UserDefaults.standard.object(forKey: "maintenance.lastRun." + id.rawValue) as? Date
    }

    var isAnyRunning: Bool { states.values.contains(.running) }

    /// Cheap and read-only: how many local snapshots exist (decides if that task is offered).
    func refresh() async {
        snapshots = await Task.detached(priority: .utility) { MaintenanceRunner.localSnapshots() }.value
        snapshotsChecked = true
    }

    func run(_ task: MaintenanceTask) async {
        guard state(task.id) != .running else { return }
        states[task.id] = .running
        // Let the spinner show before a password prompt takes over.
        try? await Task.sleep(for: .milliseconds(150))
        switch await MaintenanceRunner.run(task) {
        case .done:
            let now = Date()
            UserDefaults.standard.set(now, forKey: "maintenance.lastRun." + task.id.rawValue)
            states[task.id] = .done(now)
            if task.id == .snapshots { await refresh() }
        case .cancelled:
            states[task.id] = .idle
        case .failed(let message):
            states[task.id] = .failed(message)
        }
    }
}
