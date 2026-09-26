import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            // These two grow with every feature: scroll inside a window that fits any screen.
            Tab("Notifications", systemImage: "bell") { ScrollView { NotificationSettings().padding(.trailing, 6) }.frame(height: 560) }
            Tab("Permissions", systemImage: "hand.raised") { ScrollView { PermissionSettings().padding(.trailing, 6) }.frame(height: 560) }
        }
        .scenePadding()
        .frame(width: 560)
    }
}

/// Every permission, what it unlocks, and its live status. Changes made in System Settings show
/// up as soon as you come back.
private struct PermissionSettings: View {
    @Environment(Permissions.self) private var permissions
    @AppStorage(SettingsKeys.hasSeenWelcome) private var hasSeenWelcome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("All optional. Mac Vitals works without them; each one lets it see or do a little more.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PermissionList()
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            HStack {
                Text("Turn any of these off in System Settings › Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Show Welcome Again") { hasSeenWelcome = false }
                    .buttonStyle(.link)
                    .font(.caption)
                    .pointerStyle(.link)
                    .help("Opens the welcome screen in the Mac Vitals window")
            }
        }
        .onAppear { permissions.refreshAll() }
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKeys.refreshInterval) private var refreshInterval = 2.0
    @AppStorage(SettingsKeys.cleanupDeletesPermanently) private var deletePermanently = false
    @AppStorage(SettingsKeys.ambientMotion) private var ambientMotion = true
    @AppStorage(SettingsKeys.showDashboardAtLaunch) private var showDashboardAtLaunch = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var autoCheck = AppUpdater.shared.automaticallyChecks
    @State private var autoDownload = AppUpdater.shared.automaticallyDownloads

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Open dashboard at launch", isOn: $showDashboardAtLaunch)
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { autoCheck }, set: { autoCheck = $0; AppUpdater.shared.automaticallyChecks = $0 }))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { autoDownload }, set: { autoDownload = $0; AppUpdater.shared.automaticallyDownloads = $0 }))
                    .disabled(!autoCheck)
                HStack {
                    Text("Mac Vitals \(AppUpdater.version)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { AppUpdater.shared.checkForUpdates() }
                        .pointerStyle(.link)
                }
            }
            Section("Appearance") {
                Toggle("Ambient motion", isOn: $ambientMotion)
                Text("Backdrop transitions, entrance animations and scanning effects. Always respects Reduce Motion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Cleanup") {
                Toggle("Delete immediately instead of moving to Trash", isOn: $deletePermanently)
                Text("Off by default so every cleanup can be undone from the Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Which alerts Mac Vitals may send. Everything is rate-limited and nothing is sent while you're
/// looking at Mac Vitals.
private struct NotificationSettings: View {
    @Environment(Permissions.self) private var permissions
    @State private var enabled: [AlertKind: Bool] = Dictionary(uniqueKeysWithValues: AlertKind.allCases.map { ($0, AlertCenter.isEnabled($0)) })
    @State private var testSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !permissions.isGranted(.notifications) {
                PermissionRow(kind: .notifications, compact: true)
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            }
            Text("Only things worth interrupting you for. Each alert waits until a problem lasts (a spike isn't a problem), won't repeat for hours unless it gets worse, and never shows while Mac Vitals is on screen. macOS Focus modes are respected.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(AlertKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider().padding(.leading, 40) }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: kind.icon).foregroundStyle(.secondary).frame(width: 22).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).font(.body.weight(.medium))
                            Text(kind.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { enabled[kind] ?? kind.enabledByDefault },
                            set: { value in
                                enabled[kind] = value
                                UserDefaults.standard.set(value, forKey: kind.settingsKey)
                            }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small).pointerStyle(.link)
                    }
                    .padding(.vertical, 8)
                    .opacity(permissions.isGranted(.notifications) ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            HStack {
                Button(testSent ? "Sent" : "Send a Test Notification") {
                    AlertCenter.shared.sendTest()
                    testSent = true
                }
                .buttonStyle(.link).font(.callout).pointerStyle(.link)
                .disabled(!permissions.isGranted(.notifications))
                Spacer()
                Button("macOS Notification Settings…") { permissions.openSettings(for: .notifications) }
                    .buttonStyle(.link).font(.callout).pointerStyle(.link)
            }
        }
        .onAppear { permissions.refresh(.notifications) }
    }
}
