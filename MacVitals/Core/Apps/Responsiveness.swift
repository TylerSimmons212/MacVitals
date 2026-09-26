import AppKit
import ApplicationServices
import Observation

/// An app that stopped answering (what macOS shows as "Not Responding" and a spinning cursor).
struct FrozenApp: Identifiable, Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundlePath: String?
    /// First missed check.
    let since: Date

    var id: pid_t { pid }
    func seconds(now: Date = Date()) -> Int { max(0, Int(now.timeIntervalSince(since))) }
}

/// Spots frozen apps the official way: ask each app a trivial question through Accessibility
/// with a 1-second time limit. A frozen app can't answer (its main thread is stuck), a healthy
/// one answers in milliseconds. Needs the Accessibility permission; without it, this stays off.
///
/// An app counts as frozen only after missing two checks in a row, so a brief hiccup isn't
/// reported. (macOS's own window-server flag proved unreliable on macOS 26 in testing.)
@MainActor
@Observable
final class Responsiveness {
    static let shared = Responsiveness()

    private(set) var frozen: [FrozenApp] = []
    @ObservationIgnored private var misses: [pid_t: (count: Int, since: Date)] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?

    enum Probe: Equatable, Sendable { case answered, noAnswer, unknown }

    static let missesBeforeFrozen = 2

    /// `watched`: check every 10 s while a window is open, every 20 s otherwise.
    func start(isWatched: @escaping @MainActor () -> Bool) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if AXIsProcessTrusted() { await self.checkOnce() } else if !self.frozen.isEmpty { self.frozen = [] }
                try? await Task.sleep(for: .seconds(isWatched() ? 10 : 20))
            }
        }
    }

    func checkOnce(now: Date = Date()) async {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.isFinishedLaunching && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map { (pid: $0.processIdentifier, name: $0.localizedName ?? "An app", path: $0.bundleURL?.path) }
        let pids = candidates.map(\.pid)
        // Each check can block up to a second on a frozen app: run them together off the main thread.
        let results: [pid_t: Probe] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var answers = [Probe](repeating: .unknown, count: pids.count)
                answers.withUnsafeMutableBufferPointer { buffer in
                    DispatchQueue.concurrentPerform(iterations: pids.count) { buffer[$0] = Responsiveness.probe(pids[$0]) }
                }
                continuation.resume(returning: Dictionary(uniqueKeysWithValues: zip(pids, answers)))
            }
        }
        record(results, names: Dictionary(uniqueKeysWithValues: candidates.map { ($0.pid, ($0.name, $0.path)) }), now: now)
    }

    /// Pure bookkeeping, separated for tests.
    func record(_ results: [pid_t: Probe], names: [pid_t: (String, String?)], now: Date) {
        var next: [pid_t: (count: Int, since: Date)] = [:]
        for (pid, probe) in results where probe == .noAnswer {
            let previous = misses[pid]
            next[pid] = ((previous?.count ?? 0) + 1, previous?.since ?? now)
        }
        misses = next
        let updated = next.filter { $0.value.count >= Self.missesBeforeFrozen }.compactMap { pid, miss -> FrozenApp? in
            guard let (name, path) = names[pid] else { return nil }
            return FrozenApp(pid: pid, name: name, bundlePath: path, since: miss.since)
        }.sorted { $0.since < $1.since }
        if updated != frozen { frozen = updated }
    }

    nonisolated static func probe(_ pid: pid_t) -> Probe {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) {
        case .success: return .answered
        case .cannotComplete: return .noAnswer
        default: return .unknown
        }
    }

    /// Unsaved changes in a frozen app are lost either way; this ends it immediately.
    func forceQuit(_ app: FrozenApp) {
        NSRunningApplication(processIdentifier: app.pid)?.forceTerminate()
        frozen.removeAll { $0.pid == app.pid }
        misses[app.pid] = nil
    }
}
