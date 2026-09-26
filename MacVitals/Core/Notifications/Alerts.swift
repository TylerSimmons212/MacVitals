import Foundation

/// The kinds of things Mac Vitals will interrupt you for. Each is a switch in Settings.
enum AlertKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case storage, memory, heat, stuckApps, battery, protection, importantUpdates, updateDigest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .storage: "Disk almost full"
        case .memory: "Memory running out"
        case .heat: "Mac running hot"
        case .stuckApps: "Apps stuck or leaking memory"
        case .battery: "Battery needs service"
        case .protection: "A protection is turned off"
        case .importantUpdates: "Important app updates"
        case .updateDigest: "Weekly: app updates available"
        }
    }

    var detail: String {
        switch self {
        case .storage: "When the startup disk is nearly full. At most once a day, sooner if it gets worse."
        case .memory: "When memory pressure stays critical for a few minutes."
        case .heat: "When macOS keeps slowing your Mac down to cool it."
        case .stuckApps: "An app busy nonstop for 10+ minutes, or one whose memory keeps growing. With a Quit button."
        case .battery: "When macOS says the battery needs service. Once a month at most."
        case .protection: "If FileVault, Gatekeeper or another built-in protection gets switched off. Checked every few hours."
        case .importantUpdates: "Updates developers mark as critical, usually security fixes. Once per update."
        case .updateDigest: "A short summary once a week, if any apps have updates."
        }
    }

    var icon: String {
        switch self {
        case .storage: "internaldrive"
        case .memory: "memorychip"
        case .heat: "thermometer.high"
        case .stuckApps: "exclamationmark.triangle"
        case .battery: "battery.25percent"
        case .protection: "checkmark.shield"
        case .importantUpdates: "arrow.down.app"
        case .updateDigest: "calendar"
        }
    }

    /// On unless it's the kind of thing that could feel like nagging.
    var enabledByDefault: Bool { self != .updateDigest }

    var settingsKey: String { "alerts." + rawValue }
}

/// One thing worth telling you about, right now.
struct Alert: Equatable, Sendable {
    let id: String
    let kind: AlertKind
    let severity: Int
    let title: String
    let body: String
    let section: DashboardSection
    /// Must be true this long before we say anything (a spike isn't a problem).
    var persistence: TimeInterval = 0
    /// After telling you, stay quiet this long about the same thing, unless it gets worse.
    var cooldown: TimeInterval = 6 * 3600
    /// For "Quit" on stuck-app alerts.
    var appID: String? = nil
    var appName: String? = nil
}

/// Decides what to actually send: things that have lasted long enough, that you haven't just
/// been told about (unless they got worse), never while you're looking at Mac Vitals, and never
/// more than a few an hour. Pure, so every rule is unit-tested.
struct AlertPolicy: Codable, Sendable {
    struct Sent: Codable, Sendable, Equatable {
        let date: Date
        let severity: Int
    }

    /// When each current condition started (in memory; conditions restart after relaunch).
    private(set) var firstSeen: [String: Date] = [:]
    /// Persisted: when we last told you about each thing.
    private(set) var lastSent: [String: Sent] = [:]
    private(set) var recentSends: [Date] = []

    static let maxPerHour = 3

    enum CodingKeys: String, CodingKey { case lastSent, recentSends }

    init() {}

    /// `keeping`: conditions tracked by another caller, left alone.
    mutating func evaluate(_ conditions: [Alert], now: Date, userIsLooking: Bool, keeping: Set<String> = []) -> [Alert] {
        let current = Set(conditions.map(\.id)).union(keeping)
        firstSeen = firstSeen.filter { current.contains($0.key) }
        recentSends.removeAll { now.timeIntervalSince($0) > 3600 }

        var toSend: [Alert] = []
        for alert in conditions.sorted(by: { $0.severity > $1.severity }) {
            let since = firstSeen[alert.id] ?? now
            firstSeen[alert.id] = since
            guard now.timeIntervalSince(since) >= alert.persistence else { continue }
            if let last = lastSent[alert.id], now.timeIntervalSince(last.date) < alert.cooldown, alert.severity <= last.severity {
                continue
            }
            // You'll see it on screen; don't also interrupt. It stays eligible for later.
            guard !userIsLooking else { continue }
            guard recentSends.count < Self.maxPerHour else { break }
            lastSent[alert.id] = Sent(date: now, severity: alert.severity)
            recentSends.append(now)
            toSend.append(alert)
        }
        // Forget old records so the store doesn't grow forever.
        lastSent = lastSent.filter { now.timeIntervalSince($0.value.date) < 90 * 86_400 }
        return toSend
    }

    /// Something was resolved (e.g. a protection was switched back on): allow telling you again.
    mutating func forget(_ id: String) { lastSent[id] = nil }
}

/// Turns what the monitor sees into alerts, in plain words.
enum AlertBuilder {
    static func conditions(report: HealthReport, appFlags: [String: [AppInsights.Flag]], apps: [String: AppSnapshotInfo],
                           topMemoryApp: String?, topCPUApp: String?, enabled: Set<AlertKind>) -> [Alert] {
        var alerts: [Alert] = []
        func issue(_ id: String) -> HealthIssue? { report.issues.first { $0.id == id } }

        if enabled.contains(.storage), let disk = issue("disk"), disk.severity >= .warning {
            let critical = disk.severity == .critical
            alerts.append(Alert(
                id: "disk", kind: .storage, severity: disk.severity.rawValue,
                title: critical ? "Your Mac is almost out of space" : "Your startup disk is running low",
                body: "\(disk.metric.isEmpty ? "" : disk.metric + ". ")" + (critical
                    ? "When it runs out, apps can crash and updates fail. Clean Up can free space safely."
                    : "Clean Up can find caches, old installers and other things you can safely remove."),
                section: .cleanup, persistence: 60, cooldown: critical ? 6 * 3600 : 24 * 3600))
        }
        if enabled.contains(.memory), let memory = issue("memory"), memory.severity == .critical {
            alerts.append(Alert(
                id: "memory", kind: .memory, severity: 2, title: "Your Mac is short on memory",
                body: "Apps are being slowed down to make room." + (topMemoryApp.map { " \($0) is using the most." } ?? " Quitting apps you're not using helps."),
                section: .memory, persistence: 3 * 60, cooldown: 4 * 3600))
        }
        if enabled.contains(.heat), let heat = issue("thermal"), heat.severity >= .warning {
            alerts.append(Alert(
                id: "thermal", kind: .heat, severity: heat.severity.rawValue,
                title: heat.severity == .critical ? "Your Mac is overheating" : "Your Mac is running hot",
                body: "macOS is slowing it down to cool off." + (topCPUApp.map { " \($0) is the busiest app right now." } ?? ""),
                section: .cpu, persistence: 3 * 60, cooldown: 3 * 3600))
        }
        if enabled.contains(.battery), let battery = issue("battery"), battery.severity >= .warning {
            alerts.append(Alert(
                id: "battery", kind: .battery, severity: 1, title: "Your battery needs service",
                body: battery.detail, section: .battery, cooldown: 30 * 86_400))
        }
        if enabled.contains(.stuckApps) {
            for (appID, flags) in appFlags {
                guard let app = apps[appID], !app.isCurrentApp else { continue }
                for flag in flags {
                    switch flag {
                    case .stuckBusy(let cpu, let minutes):
                        alerts.append(Alert(
                            id: "stuck:" + appID, kind: .stuckApps, severity: 1, title: "\(app.name) seems stuck",
                            body: "It's been using \(Fmt.percent(cpu)) of a core for \(minutes) minutes. If you're not waiting on it, quitting and reopening usually fixes it.",
                            section: .apps, cooldown: 6 * 3600, appID: appID, appName: app.name))
                    case .growingMemory(_, let to, let minutes):
                        alerts.append(Alert(
                            id: "leak:" + appID, kind: .stuckApps, severity: 1, title: "\(app.name)'s memory keeps growing",
                            body: "Up to \(Fmt.memory(to)) over \(minutes) minutes and not coming back down. Restarting it frees the memory.",
                            section: .apps, cooldown: 6 * 3600, appID: appID, appName: app.name))
                    }
                }
            }
        }
        return alerts
    }

    static func protection(_ checks: [DefenceCheck], enabled: Bool) -> [Alert] {
        guard enabled else { return [] }
        return checks.filter { $0.status == .off }.map { check in
            Alert(id: "protection:" + check.id.rawValue, kind: .protection, severity: 2,
                  title: "Protection off: \(check.title.lowercased())", body: check.summary,
                  section: .protection, cooldown: 30 * 86_400)
        }
    }

    static func updates(_ apps: [UpdatableApp], checks: [String: UpdateCheck], important: Bool, digest: Bool, now: Date) -> [Alert] {
        var alerts: [Alert] = []
        let available = apps.filter { checks[$0.path]?.status == .available }
        if important {
            for app in available where checks[app.path]?.isCritical == true {
                let version = checks[app.path]?.latestVersion ?? ""
                alerts.append(Alert(id: "update:\(app.path)@\(version)", kind: .importantUpdates, severity: 2,
                                    title: "Important update for \(app.name)",
                                    body: "Version \(version) is marked critical by its developer, usually a security fix.",
                                    section: .updates, cooldown: 365 * 86_400))
            }
        }
        if digest && !available.isEmpty {
            let names = ListFormatter.localizedString(byJoining: available.prefix(3).map(\.name)) + (available.count > 3 ? " and \(available.count - 3) more" : "")
            let week = Calendar.current.component(.weekOfYear, from: now)
            alerts.append(Alert(id: "digest:\(week)", kind: .updateDigest, severity: 0,
                                title: "\(available.count) app update\(available.count == 1 ? "" : "s") available",
                                body: names + ".", section: .updates, cooldown: 7 * 86_400))
        }
        return alerts
    }
}

/// What alerts need to know about a running app (kept from the last process sample).
struct AppSnapshotInfo: Sendable, Equatable {
    let name: String
    let isCurrentApp: Bool
}
