import SwiftUI
import AppKit

@main
struct MacVitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor: SystemMonitor
    @State private var router: Router
    @State private var cleanup = CleanupEngine()
    @State private var uninstaller = UninstallerModel()
    @State private var startup = StartupModel()
    @State private var storage = StorageModel()
    @State private var protection = ProtectionModel()
    @State private var spaceLens = SpaceLensModel()
    @State private var updates: UpdatesModel
    @State private var duplicates = DuplicatesModel()
    @State private var screenshots = ScreenshotsModel()
    @State private var similarPhotos = SimilarPhotosModel()
    @State private var maintenance = MaintenanceModel()
    @State private var extensions = ExtensionsModel()
    /// Read once at launch. (Reading it via @AppStorage in `body` isn't honored for launch behavior.)
    private let dashboardLaunchBehavior: SceneLaunchBehavior

    init() {
        let monitor = SystemMonitor()
        monitor.start()
        _monitor = State(initialValue: monitor)
        AppDelegate.monitor = monitor
        AppActivity.shared.start()
        let router = Router()
        let updates = UpdatesModel()
        _router = State(initialValue: router)
        _updates = State(initialValue: updates)
        // Clicking a notification opens the dashboard on the relevant page.
        AlertCenter.shared.openSection = { section in
            router.section = section
            NotificationCenter.default.post(name: .openDashboard, object: nil)
        }
        AlertCenter.shared.configure(updates: updates)
        _ = AppUpdater.shared // starts Sparkle's daily check
        let showDashboard = UserDefaults.standard.object(forKey: SettingsKeys.showDashboardAtLaunch) as? Bool ?? true
        dashboardLaunchBehavior = showDashboard ? .presented : .suppressed
    }

    var body: some Scene {
        Window("Mac Vitals", id: WindowID.dashboard) {
            DashboardView()
                .showsDockIconWhileOpen("dashboard")
                .environment(monitor)
                .environment(router)
                .environment(cleanup)
                .environment(uninstaller)
                .environment(startup)
                .environment(storage)
                .environment(protection)
                .environment(spaceLens)
                .environment(updates)
                .environment(duplicates)
                .environment(screenshots)
                .environment(similarPhotos)
                .environment(maintenance)
                .environment(extensions)
                .environment(Permissions.shared)
                .environment(AppActivity.shared)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 780)
        .defaultLaunchBehavior(dashboardLaunchBehavior)
        // Otherwise macOS window restoration reopens the dashboard and ignores the setting.
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                    .disabled(!AppUpdater.shared.canCheckForUpdates)
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(monitor)
                .environment(router)
                .environment(cleanup)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .showsDockIconWhileOpen("settings")
                .environment(Permissions.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var monitor: SystemMonitor?

    /// We launch as a menu bar app (LSUIElement). If the dashboard will open, switch to a regular
    /// app *before* launch finishes; otherwise macOS doesn't activate us and the window opens
    /// behind whatever you were using.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let showDashboard = UserDefaults.standard.object(forKey: SettingsKeys.showDashboardAtLaunch) as? Bool ?? true
        if showDashboard {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.monitor?.saveHistory() }
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// Save history when terminated by a signal too (logout, updates, `kill`), not just ⌘Q.
    func applicationDidFinishLaunching(_ notification: Notification) {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { Self.monitor?.saveHistory() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Keep monitoring from the menu bar after the dashboard window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Launching the app again while it's running (Finder, Spotlight, Launchpad) opens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .openDashboard, object: nil)
        }
        return true
    }
}
