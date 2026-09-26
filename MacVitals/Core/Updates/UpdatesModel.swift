import Foundation
import AppKit
import Observation

/// Finds updates for installed apps from their own sources (developer feeds, the App Store,
/// Homebrew) and installs the ones it safely can.
@MainActor
@Observable
final class UpdatesModel {
    enum Phase: Equatable { case idle, checking, ready }

    enum InstallState: Equatable {
        case working(UpdateInstaller.Step)
        case updating(String) // Homebrew, App Store handoff…
        case done(String)
        case failed(UpdateInstaller.Failure)
    }

    private(set) var phase: Phase = .idle
    private(set) var apps: [UpdatableApp] = []
    private(set) var checks: [String: UpdateCheck] = [:]
    private(set) var installs: [String: InstallState] = [:]
    private(set) var lastCheck: Date?
    @ObservationIgnored private var staged: [String: UpdateInstaller.Staged] = [:]
    @ObservationIgnored private var brew: [String: UpdateSources.BrewCask] = [:]

    var available: [UpdatableApp] {
        apps.filter { checks[$0.path]?.status == .available && !isDone($0) }
            .sorted { (checks[$0.path]?.isCritical == true ? 0 : 1, $0.name) < (checks[$1.path]?.isCritical == true ? 0 : 1, $1.name) }
    }
    var upToDate: [UpdatableApp] { apps.filter { checks[$0.path]?.status == .upToDate || isDone($0) } }
    var selfUpdating: [UpdatableApp] {
        apps.filter { app in
            if case .selfUpdating = app.source { return true }
            return checks[app.path]?.status == .notCheckable && app.source != .unknown && app.source != .macOS
        }
    }
    var needsNewerMacOS: [UpdatableApp] {
        apps.filter { if case .needsNewerMacOS = checks[$0.path]?.status { true } else { false } }
    }
    var failedChecks: [UpdatableApp] { apps.filter { if case .failed = checks[$0.path]?.status { true } else { false } } }
    var uncheckable: [UpdatableApp] { apps.filter { $0.source == .unknown } }
    var macOSApps: [UpdatableApp] { apps.filter { $0.source == .macOS } }
    var checkedCount: Int { apps.filter { $0.source.isCheckable }.count }

    /// Updates Mac Vitals can do in one click (from a developer feed or Homebrew).
    var oneClick: [UpdatableApp] { available.filter { $0.source.canInstallHere && $0.bundleID != Bundle.main.bundleIdentifier } }

    private func isDone(_ app: UpdatableApp) -> Bool {
        if case .done = installs[app.path] { return true }
        return false
    }

    // MARK: Checking

    func check() async {
        guard phase != .checking else { return }
        phase = .checking
        let (inventory, casks) = await Task.detached(priority: .userInitiated) { () -> ([UpdatableApp], [String: UpdateSources.BrewCask]) in
            let casks = UpdateSources.brewCasks()
            return (UpdateSources.inventory(brewCasks: casks), casks)
        }.value
        brew = casks
        apps = inventory

        var results: [String: UpdateCheck] = [:]
        await withTaskGroup(of: [String: UpdateCheck].self) { group in
            let storeApps = inventory.filter { $0.source == .appStore }
            group.addTask { await UpdateSources.checkAppStore(storeApps) }
            for app in inventory {
                switch app.source {
                case .sparkle(let feed):
                    group.addTask { [app.path: await UpdateSources.checkSparkle(app, feed: feed)] }
                case .homebrew:
                    if let cask = casks[URL(fileURLWithPath: app.path).lastPathComponent] {
                        results[app.path] = UpdateSources.evaluateBrew(app, cask: cask)
                    }
                case .selfUpdating, .macOS, .unknown:
                    results[app.path] = UpdateCheck(status: .notCheckable)
                case .appStore:
                    break
                }
            }
            for await partial in group { results.merge(partial) { $1 } }
        }
        checks = results
        installs = installs.filter { if case .done = $0.value { false } else { true } }
        lastCheck = Date()
        phase = .ready
    }

    // MARK: Updating

    func update(_ app: UpdatableApp) async {
        // Mac Vitals itself: Sparkle does it (it can quit and relaunch us safely).
        if app.bundleID == Bundle.main.bundleIdentifier {
            AppUpdater.shared.checkForUpdates()
            return
        }
        guard let check = checks[app.path] else { return }
        switch app.source {
        case .appStore:
            if let url = check.storeURL ?? URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
            installs[app.path] = .updating("Finish in the App Store")
        case .homebrew(let token):
            await brewUpgrade(app, token: token)
        case .sparkle:
            await installFromFeed(app, check: check)
        case .selfUpdating, .macOS, .unknown:
            NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
        }
    }

    func updateAll() async {
        for app in oneClick where installs[app.path] == nil { await update(app) }
    }

    private func installFromFeed(_ app: UpdatableApp, check: UpdateCheck, viaFinder: Bool = false) async {
        do {
            let ready: UpdateInstaller.Staged
            if let existing = staged[app.path] {
                ready = existing
            } else {
                guard let url = check.downloadURL else { throw UpdateInstaller.Failure.download("no download link in the feed") }
                installs[app.path] = .working(.downloading(0))
                let path = app.path
                ready = try await UpdateInstaller.stage(app, from: url) { step in
                    Task { @MainActor [weak self] in
                        guard let self, case .working = self.installs[path] else { return }
                        self.installs[path] = .working(step)
                    }
                }
                staged[app.path] = ready
            }
            installs[app.path] = .working(.installing)
            try await UpdateInstaller.install(ready, over: app, viaFinder: viaFinder)
            staged[app.path] = nil
            installs[app.path] = .done("Updated to \(check.latestVersion ?? "the latest version")")
            Permissions.learnAppManagement(allowed: true)
        } catch let failure as UpdateInstaller.Failure {
            installs[app.path] = .failed(failure)
            if failure == .needsAppManagement { Permissions.learnAppManagement(allowed: false) }
        } catch {
            installs[app.path] = .failed(.failed(error.localizedDescription))
        }
    }

    /// After allowing App Management, or with Finder + password for apps installed for all users.
    func retry(_ app: UpdatableApp, viaFinder: Bool = false) async {
        guard let check = checks[app.path] else { return }
        await installFromFeed(app, check: check, viaFinder: viaFinder)
    }

    private func brewUpgrade(_ app: UpdatableApp, token: String) async {
        installs[app.path] = .updating("Updating with Homebrew…")
        let (status, output) = await Task.detached(priority: .userInitiated) {
            var env = UpdateSources.brewEnvironment()
            env.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE") // fetch the newest definition first
            return UpdateSources.runBrew(["upgrade", "--cask", token], environment: env)
        }.value
        if status == 0 {
            installs[app.path] = .done("Updated with Homebrew")
        } else if output.localizedCaseInsensitiveContains("sudo") || output.localizedCaseInsensitiveContains("password") {
            installs[app.path] = .failed(.failed("Homebrew needs your password for this one. Run brew upgrade --cask \(token) in Terminal."))
        } else {
            let reason = output.split(separator: "\n").last { $0.contains("Error") }.map(String.init) ?? "Homebrew couldn't update it."
            installs[app.path] = .failed(.failed(reason))
        }
    }

    func dismissFailure(_ app: UpdatableApp) {
        installs[app.path] = nil
        if let stagedCopy = staged.removeValue(forKey: app.path) { try? FileManager.default.removeItem(at: stagedCopy.workDirectory) }
    }
}

extension UpdatableApp.Source {
    var isCheckable: Bool {
        switch self {
        case .sparkle, .appStore, .homebrew: true
        case .selfUpdating, .macOS, .unknown: false
        }
    }

    var canInstallHere: Bool {
        switch self {
        case .sparkle, .homebrew: true
        default: false
        }
    }
}
