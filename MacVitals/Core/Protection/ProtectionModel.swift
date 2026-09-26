import Foundation
import Observation

/// Runs the Protection checks off the main thread and publishes the results once.
/// Nothing here runs in the background or on a timer: it checks when you open the page.
@MainActor
@Observable
final class ProtectionModel {
    enum Phase: Equatable { case idle, checking, ready }

    private(set) var phase: Phase = .idle
    private(set) var defences: [DefenceCheck] = []
    private(set) var startup: [PersistenceAudit.Review] = []
    private(set) var appsChecked = 0
    private(set) var unverifiedApps: [AppSignatureAudit.Review] = []
    private(set) var lastCheck: Date?
    /// Whether the startup check covered macOS's complete list (see `BTMAccess`).
    private(set) var startupComplete = StartupInventory.isComplete
    /// Browser extensions forced on by a policy, or installed outside the store with access to every site.
    private(set) var suspiciousExtensions: [BrowserExtension] = []

    var coreDefences: [DefenceCheck] { defences.filter(\.isCoreDefence) }
    var coreDefencesOn: Int { coreDefences.filter { $0.status == .on }.count }
    var flaggedStartup: [PersistenceAudit.Review] {
        startup.filter { $0.level > .fine }.sorted { ($0.level, $1.item.name) > ($1.level, $0.item.name) }
    }
    var suspiciousCount: Int { startup.filter { $0.level == .suspicious }.count }

    /// Things that need action: defences that are off, plus suspicious startup items.
    var attentionCount: Int { defences.filter(\.status.needsAttention).count + suspiciousCount + suspiciousExtensions.count }

    /// Asks for your password once, then re-checks with the complete list.
    func includeEverything() async {
        try? await Task.sleep(for: .milliseconds(150))
        if BTMAccess.readWithPassword() { await check() }
    }

    func check() async {
        guard phase != .checking else { return }
        phase = .checking

        async let fast = Task.detached(priority: .userInitiated) { DefenceChecks.runFast() }.value
        async let startupReviews = Task.detached(priority: .userInitiated) {
            StartupInventory.scan().map { PersistenceAudit.review($0) }
        }.value
        async let apps = Task.detached(priority: .utility) { AppSignatureAudit.run() }.value
        async let extensions = Task.detached(priority: .utility) { BrowserExtensions.all().filter { $0.level == .suspicious } }.value

        var checks = await fast
        // Keep the last macOS-updates answer while re-checking, instead of flashing back to "Checking".
        let previousUpdates = defences.first { $0.id == .macOSUpdates }
        checks.insert(previousUpdates ?? DefenceChecks.macOSUpdatesChecking, at: 3)
        defences = checks
        startup = await startupReviews
        startupComplete = StartupInventory.isComplete
        let appResult = await apps
        appsChecked = appResult.checked
        unverifiedApps = appResult.unverified
        suspiciousExtensions = await extensions
        lastCheck = Date()
        phase = .ready

        // Slowest check last: it talks to Apple's servers.
        let updates = await Task.detached(priority: .utility) { DefenceChecks.macOSUpdates() }.value
        if let index = defences.firstIndex(where: { $0.id == .macOSUpdates }) { defences[index] = updates }
    }
}
