import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Permissions", systemImage: "hand.raised") { PermissionSettings() }
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
