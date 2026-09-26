import Foundation
import AppKit
import UserNotifications

/// Sends Mac Vitals' notifications. Fed by the monitor (which keeps sampling in the
/// background) plus a slow background check for protections and updates. What gets sent, and
/// how often, is decided by `AlertPolicy`.
@MainActor
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()

    /// Opens the dashboard at a section (set by the app at launch).
    var openSection: ((DashboardSection) -> Void)?

    private var policy: AlertPolicy
    private var apps: [String: AppUsage] = [:]
    private var lastEvaluation = Date.distantPast
    private var backgroundChecks: Task<Void, Never>?
    private weak var updates: UpdatesModel?

    private static let policyKey = "alerts.policy"
    private static let quitAction = "quit"
    private static let showAction = "show"
    private static let appCategory = "app"

    override init() {
        policy = UserDefaults.standard.data(forKey: Self.policyKey)
            .flatMap { try? JSONDecoder().decode(AlertPolicy.self, from: $0) } ?? AlertPolicy()
        super.init()
    }

    // MARK: Setup

    func configure(updates: UpdatesModel) {
        self.updates = updates
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let quit = UNNotificationAction(identifier: Self.quitAction, title: "Quit", options: [])
        let show = UNNotificationAction(identifier: Self.showAction, title: "Show", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.appCategory, actions: [quit, show], intentIdentifiers: []),
        ])
        startBackgroundChecks()
    }

    static func isEnabled(_ kind: AlertKind) -> Bool {
        UserDefaults.standard.object(forKey: kind.settingsKey) as? Bool ?? kind.enabledByDefault
    }

    static var enabledKinds: Set<AlertKind> { Set(AlertKind.allCases.filter(isEnabled)) }

    // MARK: From the monitor

    /// Called on every sample; does real work at most every 30 s.
    func observe(report: HealthReport, flags: @autoclosure () -> [String: [AppInsights.Flag]], apps latest: [AppUsage]?, userIsLooking: Bool) {
        if let latest { apps = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        let now = Date()
        guard now.timeIntervalSince(lastEvaluation) >= 30, Permissions.shared.isGranted(.notifications) else { return }
        lastEvaluation = now
        let enabled = Self.enabledKinds
        guard !enabled.isEmpty else { return }
        let visible = apps.values.filter { $0.kind != .system && !$0.isCurrentApp }
        let conditions = AlertBuilder.conditions(
            report: report, appFlags: enabled.contains(.stuckApps) ? flags() : [:],
            apps: apps.mapValues { AppSnapshotInfo(name: $0.name, isCurrentApp: $0.isCurrentApp) },
            topMemoryApp: visible.max { $0.memory < $1.memory }?.name,
            topCPUApp: visible.max { $0.cpu < $1.cpu }?.name,
            enabled: enabled)
        deliver(conditions, userIsLooking: userIsLooking, now: now, kinds: [.storage, .memory, .heat, .battery, .stuckApps])
    }

    // MARK: Background checks (protections every 6 h, updates daily)

    private func startBackgroundChecks() {
        backgroundChecks?.cancel()
        backgroundChecks = Task { [weak self] in
            // Let launch settle first.
            try? await Task.sleep(for: .seconds(90))
            var lastUpdateCheck = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if Permissions.shared.isGranted(.notifications) {
                    if Self.isEnabled(.protection) {
                        let checks = await Task.detached(priority: .background) { DefenceChecks.runFast() }.value
                        // Resolved ones can be reported again if they're switched off later.
                        for check in checks where check.status == .on { self.policy.forget("protection:" + check.id.rawValue) }
                        self.deliver(AlertBuilder.protection(checks, enabled: true), userIsLooking: false, now: Date(), kinds: [.protection])
                    }
                    let wantsUpdates = Self.isEnabled(.importantUpdates) || Self.isEnabled(.updateDigest)
                    if wantsUpdates, Date().timeIntervalSince(lastUpdateCheck) > 20 * 3600, let updates = self.updates {
                        lastUpdateCheck = Date()
                        if updates.lastCheck.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true { await updates.check() }
                        let alerts = AlertBuilder.updates(updates.apps, checks: updates.checks,
                                                          important: Self.isEnabled(.importantUpdates),
                                                          digest: Self.isEnabled(.updateDigest), now: Date())
                        self.deliver(alerts, userIsLooking: false, now: Date(), kinds: [.importantUpdates, .updateDigest])
                    }
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: Delivery

    /// Background checks and the monitor each own some kinds; conditions for kinds they own
    /// that are absent now are treated as resolved.
    private func deliver(_ conditions: [Alert], userIsLooking: Bool, now: Date, kinds: Set<AlertKind>) {
        let others = policy.firstSeenIDs(excludingKinds: kinds)
        let toSend = policy.evaluate(conditions, now: now, userIsLooking: userIsLooking, keeping: others)
        save()
        toSend.forEach(post)
    }

    private func post(_ alert: Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.severity >= 2 ? .default : nil
        content.userInfo = ["section": alert.section.rawValue, "app": alert.appID ?? ""]
        content.threadIdentifier = alert.kind.rawValue
        if alert.appID != nil { content.categoryIdentifier = Self.appCategory }
        content.interruptionLevel = alert.severity >= 2 ? .active : .passive
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Notifications are on"
        content.body = "This is how Mac Vitals will let you know when something needs attention."
        content.userInfo = ["section": DashboardSection.overview.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(UUID())", content: content, trigger: nil))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(data, forKey: Self.policyKey) }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let section = (info["section"] as? String).flatMap(DashboardSection.init(rawValue:)) ?? .overview
        let appID = info["app"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Self.quitAction, let appID, let app = self.apps[appID], ProcessController.canQuit(app) {
                ProcessController.quit(app, force: false)
            } else {
                self.openSection?(section)
            }
        }
    }
}

extension AlertPolicy {
    /// Conditions currently tracked for other kinds (so one caller doesn't reset another's timers).
    func firstSeenIDs(excludingKinds kinds: Set<AlertKind>) -> Set<String> {
        let prefixes: [AlertKind: [String]] = [
            .storage: ["disk"], .memory: ["memory"], .heat: ["thermal"], .battery: ["battery"],
            .stuckApps: ["stuck:", "leak:"], .protection: ["protection:"], .importantUpdates: ["update:"], .updateDigest: ["digest:"],
        ]
        let owned = kinds.flatMap { prefixes[$0] ?? [] }
        return Set(firstSeen.keys.filter { id in !owned.contains { id.hasPrefix($0) } })
    }
}
