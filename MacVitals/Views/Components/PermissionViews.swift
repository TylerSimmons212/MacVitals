import SwiftUI

extension PermissionKind {
    var tint: Color {
        switch self {
        case .fullDiskAccess: .orange
        case .location: Theme.network
        case .appManagement: .blue
        case .finder: .indigo
        case .photos: .pink
        case .notifications: .red
        case .accessibility: .purple
        }
    }
}

/// One permission, explained by what it unlocks, with its live status and the one button that
/// grants it. Used on the Welcome screen and in Settings › Permissions.
struct PermissionRow: View {
    let kind: PermissionKind
    var compact = false
    @Environment(Permissions.self) private var permissions

    var body: some View {
        let status = permissions.status(kind)
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(kind.tint.gradient)
                Image(systemName: kind.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kind.benefit).font(.headline)
                    if kind.isRecommended && status != .granted {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(kind.tint)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(kind.tint.opacity(0.15)))
                    }
                }
                Text(kind.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill").font(.caption2)
                        Text(kind.privacyNote)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PermissionControl(kind: kind)
                .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, compact ? 8 : 10)
        .animation(.smooth, value: status)
    }
}

/// Status pill or the button that asks, depending on where the permission stands.
struct PermissionControl: View {
    let kind: PermissionKind
    @Environment(Permissions.self) private var permissions

    var body: some View {
        let status = permissions.status(kind)
        Group {
            if status == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                    .help(kind == .appManagement
                          ? "Confirmed by you or by a successful uninstall. If an uninstall is ever blocked, Mac Vitals will ask again."
                          : "On in System Settings › Privacy & Security › \(kind.systemName)")
            } else if kind == .appManagement && status == .unknown {
                // macOS keeps this switch private even from apps with Full Disk Access, so don't
                // nag with "Allow": say so, and let you confirm it once.
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Button("It's On") { permissions.confirmAppManagementOn() }
                            .buttonStyle(.glass)
                            .pointerStyle(.link)
                            .help("You've already switched Mac Vitals on under App Management")
                        Button("Open Settings") { permissions.request(kind) }
                            .buttonStyle(.glassProminent)
                            .tint(kind.tint)
                            .pointerStyle(.link)
                    }
                    Text("macOS doesn't let apps check this one")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if permissions.waitingFor == kind {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting…").font(.callout).foregroundStyle(.secondary)
                }
                .help("Turn on Mac Vitals under \(kind.systemName). We'll notice right away.")
            } else {
                Button(status == .denied ? "Open Settings" : "Allow") {
                    permissions.request(kind)
                }
                .buttonStyle(.glassProminent)
                .tint(kind.tint)
                .pointerStyle(.link)
                .help(status == .denied
                      ? "It was turned off. Turn Mac Vitals back on under \(kind.systemName)."
                      : "Opens \(kind.systemName) in System Settings")
            }
        }
    }
}

/// Inline, in-context ask: what's missing on this page and the button that fixes it.
struct PermissionCallout: View {
    let kind: PermissionKind
    let message: String
    var onGranted: (() -> Void)? = nil
    @Environment(Permissions.self) private var permissions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .font(.title3)
                .foregroundStyle(kind.tint)
                .frame(width: 26)
            Text(permissions.waitingFor == kind
                 ? "Waiting for \(kind.systemName). Turn on Mac Vitals in System Settings and this page updates by itself."
                 : message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if permissions.waitingFor == kind {
                ProgressView().controlSize(.small)
            } else {
                Button(permissions.status(kind) == .denied ? "Open Settings" : "Allow Access") {
                    permissions.request(kind, then: onGranted)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .pointerStyle(.link)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(kind.tint.opacity(0.08)))
    }
}

/// All permissions in one list (Settings, Welcome).
struct PermissionList: View {
    var kinds: [PermissionKind] = PermissionKind.allCases
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider().padding(.leading, 52) }
                PermissionRow(kind: kind, compact: compact)
            }
        }
    }
}

/// Offered where the startup list matters: macOS keeps its complete list behind an admin
/// password, so Mac Vitals asks only when you choose to, with its own prompt.
struct CompleteStartupListCallout: View {
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.title3)
                .foregroundStyle(Theme.protection)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some login items are only visible with your password")
                    .font(.callout.weight(.semibold))
                Text("macOS keeps its complete list private. Mac Vitals can read it once for this session. It only reads the list; nothing is changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Button("Show Complete List…", action: action)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerStyle(.link)
                    .help("macOS will ask for your password on behalf of Mac Vitals")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.protection.opacity(0.08)))
    }
}
