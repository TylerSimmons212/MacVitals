import AppKit
import Observation

/// Remembers when you last switched to each app, using macOS's app-activation notifications.
/// Costs nothing and needs no permissions. Powers "Last used 3 h ago" and the
/// "Free up memory" suggestions (heavy apps you haven't touched in a while).
@MainActor
@Observable
final class AppActivity {
    static let shared = AppActivity()

    /// Bundle path → last time it was the frontmost app.
    private(set) var lastUsed: [String: Date] = [:]
    /// When tracking began. Apps not seen since then haven't been used since at least this time.
    private(set) var trackingSince: Date
    private(set) var frontmostBundlePath: String?

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var started = false

    private static let lastUsedKey = "appLastUsed"
    private static let sinceKey = "appActivitySince"

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.dictionary(forKey: Self.lastUsedKey) as? [String: Double] {
            lastUsed = stored.mapValues { Date(timeIntervalSinceReferenceDate: $0) }
        }
        let since = defaults.double(forKey: Self.sinceKey)
        trackingSince = since > 0 ? Date(timeIntervalSinceReferenceDate: since) : Date()
        if since == 0 { defaults.set(trackingSince.timeIntervalSinceReferenceDate, forKey: Self.sinceKey) }
    }

    func start() {
        guard !started else { return }
        started = true
        if let front = NSWorkspace.shared.frontmostApplication { record(front) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.record(app) }
        }
    }

    private func record(_ app: NSRunningApplication) {
        guard let path = app.bundleURL?.path else { return }
        // The app you're leaving was in use right up until now.
        if let previous = frontmostBundlePath, previous != path { lastUsed[previous] = Date() }
        lastUsed[path] = Date()
        frontmostBundlePath = path
        UserDefaults.standard.set(lastUsed.mapValues(\.timeIntervalSinceReferenceDate), forKey: Self.lastUsedKey)
    }

    /// When the app was last in front. The frontmost app counts as "now".
    func lastUsed(bundlePath: String) -> Date? {
        if bundlePath == frontmostBundlePath { return Date() }
        return lastUsed[bundlePath]
    }
}
