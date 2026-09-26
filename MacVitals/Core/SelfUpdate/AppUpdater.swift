import AppKit
import Observation
import Sparkle

/// Mac Vitals' own updates, via Sparkle (the same setup as Speek and VideoPro): an appcast
/// published with each GitHub release, every update signed with our EdDSA key and our
/// Developer ID, and checked once a day.
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        bringForward()
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// We're a menu bar app: show Sparkle's windows in front, with a Dock icon while they're up.
    private func bringForward() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Background app: let Sparkle show gentle reminders instead of stealing focus at random.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Task { @MainActor in self.bringForward() }
    }
}
