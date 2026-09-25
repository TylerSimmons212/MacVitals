import AppKit
import Darwin

/// Quitting and force-quitting. Prefers AppKit's polite terminate for real apps.
@MainActor
enum ProcessController {
    static func canQuit(_ app: AppUsage) -> Bool {
        guard app.kind != .system else { return false }
        return !app.processes.contains { $0.pid == getpid() }
    }

    static func quit(_ app: AppUsage, force: Bool) {
        guard canQuit(app) else { return }
        if let bundlePath = app.bundlePath {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundlePath }
            if !running.isEmpty {
                for app in running {
                    if force { app.forceTerminate() } else { app.terminate() }
                }
                return
            }
        }
        app.processes.forEach { signal($0.pid, force: force) }
    }

    static func signal(_ pid: pid_t, force: Bool) {
        guard pid > 1, pid != getpid() else { return }
        kill(pid, force ? SIGKILL : SIGTERM)
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}
