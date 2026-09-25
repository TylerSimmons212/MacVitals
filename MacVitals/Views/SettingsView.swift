import SwiftUI
import ServiceManagement

struct SettingsView: View {
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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
