import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview, cpu, memory, disk, network, battery
    case apps, updates, ports, protection
    case cleanup, junk, spaceLens, uninstaller, startup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .battery: "Battery"
        case .apps: "Apps"
        case .ports: "Dev Servers"
        case .protection: "Protection"
        case .updates: "Updates"
        case .cleanup: "Smart Clean"
        case .junk: "Junk"
        case .spaceLens: "Space Lens"
        case .uninstaller: "Uninstaller"
        case .startup: "Startup Items"
        }
    }

    var icon: String {
        switch self {
        case .overview: "heart.text.square"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .battery: "battery.75percent"
        case .apps: "square.stack.3d.up"
        case .ports: "server.rack"
        case .protection: "checkmark.shield"
        case .updates: "arrow.down.app"
        case .cleanup: "sparkles"
        case .junk: "trash.circle"
        case .spaceLens: "chart.pie"
        case .uninstaller: "xmark.bin"
        case .startup: "power.circle"
        }
    }

    static let vitals: [DashboardSection] = [.overview, .cpu, .memory, .disk, .network, .battery]
    static let tools: [DashboardSection] = [.apps, .updates, .protection, .ports]
    /// Clean Up: diagnosis lives in the Vitals pages; removing things lives here.
    static let cleanUp: [DashboardSection] = [.cleanup, .junk, .spaceLens, .uninstaller, .startup]
}

@MainActor
@Observable
final class Router {
    /// `-initialSection cpu` on the command line opens a specific section (handy for profiling).
    var section: DashboardSection = UserDefaults.standard.string(forKey: "initialSection")
        .flatMap(DashboardSection.init(rawValue:)) ?? .overview
}

enum WindowID {
    static let dashboard = "dashboard"
}

enum SettingsKeys {
    static let refreshInterval = "refreshInterval"
    static let historyRange = "historyRange"
    static let cleanupDeletesPermanently = "cleanupDeletesPermanently"
    static let ambientMotion = "ambientMotion"
    static let showDashboardAtLaunch = "showDashboardAtLaunch"
    static let hasSeenWelcome = "hasSeenWelcome"
}
