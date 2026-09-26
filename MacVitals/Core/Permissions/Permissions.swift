import AppKit
import SwiftUI
import Observation
import CoreLocation
import Photos
import UserNotifications

/// Permission handling modeled on the best Mac apps (CleanMyMac, DaisyDisk, Bartender):
/// explain first, ask in context, take people to the exact setting with a drag-and-drop helper,
/// and detect the grant automatically so nobody has to click "I did it".
///
/// Everything is optional. Status is re-checked whenever Mac Vitals comes to the front, so
/// changes made in System Settings show up without a relaunch.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    /// The permission we sent someone to System Settings for, while we watch for it.
    private(set) var waitingFor: PermissionKind?

    @ObservationIgnored private var completions: [PermissionKind: [() -> Void]] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var helper: NSPanel?
    @ObservationIgnored private let helperState = HelperState()
    @ObservationIgnored private var location: LocationAuthorizer!
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    private init() {
        location = LocationAuthorizer { [weak self] in self?.locationChanged() }
        statuses[.fullDiskAccess] = Self.checkFullDiskAccess() ? .granted : .notDetermined
        statuses[.appManagement] = Self.appManagementStatus()
        statuses[.location] = location.status
        statuses[.finder] = .unknown
        statuses[.photos] = Self.photosStatus()
        statuses[.notifications] = .unknown
        statuses[.accessibility] = AXIsProcessTrusted() ? .granted : .notDetermined
        refreshNotifications()
        refreshFinder()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Permissions.shared.refreshAll() }
        }
    }

    func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .unknown }
    func isGranted(_ kind: PermissionKind) -> Bool { status(kind) == .granted }

    var hasFullDiskAccess: Bool { isGranted(.fullDiskAccess) }
    var isWaitingForFullDiskAccess: Bool { waitingFor == .fullDiskAccess }
    /// For the Settings/Welcome summary: how many of the four are on.
    var grantedCount: Int { PermissionKind.allCases.filter(isGranted).count }

    // MARK: Detection

    func refreshAll() {
        for kind in PermissionKind.allCases where kind != .finder && kind != .notifications { refresh(kind) }
        refreshNotifications()
        refreshFinder()
    }

    func refresh(_ kind: PermissionKind) {
        switch kind {
        case .fullDiskAccess: set(.fullDiskAccess, Self.checkFullDiskAccess() ? .granted : .notDetermined)
        case .appManagement: set(.appManagement, Self.appManagementStatus())
        case .location: set(.location, location.status)
        case .finder: refreshFinder()
        case .photos: set(.photos, Self.photosStatus())
        case .notifications: refreshNotifications()
        case .accessibility: set(.accessibility, AXIsProcessTrusted() ? .granted : .notDetermined)
        }
    }

    private func refreshNotifications() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self.set(.notifications, Self.status(settings.authorizationStatus))
        }
    }

    nonisolated static func status(_ authorization: UNAuthorizationStatus) -> PermissionStatus {
        switch authorization {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    private func refreshFinder() {
        Task.detached(priority: .utility) {
            let status = Permissions.finderStatus(ask: false)
            await MainActor.run { Permissions.shared.set(.finder, status) }
        }
    }

    private func set(_ kind: PermissionKind, _ status: PermissionStatus) {
        if statuses[kind] != status { statuses[kind] = status }
        if status == .granted, waitingFor == kind || completions[kind] != nil { granted(kind) }
    }

    /// There's no API to ask "do I have Full Disk Access?". The standard, reliable check is
    /// whether we can open a file that only FDA unlocks.
    nonisolated static func checkFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db"),
            home.appending(path: "Library/Safari/Bookmarks.plist"),
        ]
        for probe in probes where FileManager.default.fileExists(atPath: probe.path) {
            if let handle = try? FileHandle(forReadingFrom: probe) {
                try? handle.close()
                return true
            }
            return false
        }
        return false
    }

    /// macOS offers no way to check App Management (its record is locked even with Full Disk
    /// Access), and probing by touching another app shows a "prevented from modifying apps"
    /// alert. So we go by what the last real uninstall told us.
    nonisolated static func appManagementStatus() -> PermissionStatus {
        switch UserDefaults.standard.object(forKey: learnedAppManagementKey) as? Bool {
        case true?: return .granted
        case false?: return .denied
        case nil: return .unknown
        }
    }

    nonisolated static let learnedAppManagementKey = "permissions.appManagementLearned"

    /// Called by the remover: a successful or blocked app removal tells us the real state.
    nonisolated static func learnAppManagement(allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: learnedAppManagementKey)
        Task { @MainActor in Permissions.shared.refresh(.appManagement) }
    }

    nonisolated static func photosStatus() -> PermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    /// Whether we may send Finder Apple Events. `ask: true` shows macOS's one-time prompt
    /// (blocks until answered, so never call it on the main thread).
    nonisolated static func finderStatus(ask: Bool) -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return .unknown }
        let result = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch result {
        case noErr: return .granted
        case -1743: return .denied // errAEEventNotPermitted
        case -1744: return .notDetermined // errAEEventWouldRequireUserConsent
        default: return .unknown // e.g. Finder not running
        }
    }

    // MARK: Asking

    /// Asks for a permission the right way for its kind, and calls `then` once it's granted
    /// (immediately if it already is).
    func request(_ kind: PermissionKind, then completion: (() -> Void)? = nil) {
        refresh(kind)
        if isGranted(kind) {
            completion?()
            return
        }
        if let completion { completions[kind, default: []].append(completion) }

        switch kind {
        case .fullDiskAccess, .appManagement:
            sendToSettings(kind, showHelper: true)
        case .accessibility:
            // Adds Mac Vitals to the list (switched off) and opens the pane; the helper explains.
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
            sendToSettings(kind, showHelper: true)
        case .location:
            if CLLocationManager.locationServicesEnabled(), location.status == .notDetermined {
                location.request()
            } else {
                sendToSettings(kind, showHelper: false)
            }
        case .notifications:
            Task { @MainActor in
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus == .denied {
                    self.sendToSettings(.notifications, showHelper: false)
                    return
                }
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                let updated = await UNUserNotificationCenter.current().notificationSettings()
                self.set(.notifications, Self.status(updated.authorizationStatus))
                if !self.isGranted(.notifications) { self.completions[.notifications] = nil }
            }
        case .photos:
            if Self.photosStatus() == .denied {
                sendToSettings(.photos, showHelper: false)
            } else {
                Task { @MainActor in
                    _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    self.set(.photos, Self.photosStatus())
                    if !self.isGranted(.photos) { self.completions[.photos] = nil }
                }
            }
        case .finder:
            Task.detached(priority: .userInitiated) {
                let current = Permissions.finderStatus(ask: false)
                let answer = current == .notDetermined ? Permissions.finderStatus(ask: true) : current
                await MainActor.run {
                    let permissions = Permissions.shared
                    if answer == .denied {
                        permissions.set(.finder, .denied)
                        permissions.sendToSettings(.finder, showHelper: false)
                    } else {
                        permissions.statuses[.finder] = answer
                        if answer == .granted || answer == .unknown { permissions.granted(.finder) }
                    }
                }
            }
        }
    }

    /// Stop waiting (the person closed the helper or chose "Not now").
    func cancelRequest() {
        if let waitingFor { completions[waitingFor] = nil }
        stopPolling()
        closeHelper()
    }

    // Kept for existing call sites.
    func requestFullDiskAccess(then completion: (() -> Void)? = nil) { request(.fullDiskAccess, then: completion) }
    func cancelFullDiskAccessRequest() { cancelRequest() }

    func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    private func sendToSettings(_ kind: PermissionKind, showHelper: Bool) {
        openSettings(for: kind)
        if showHelper { self.showHelper(for: kind) }
        if kind == .appManagement {
            pollTask?.cancel()
            waitingFor = kind // cleared by Done / Not now; nothing we can poll
        } else {
            startPolling(kind)
        }
    }

    private func locationChanged() {
        set(.location, location.status)
        if location.status == .denied, completions[.location] != nil { completions[.location] = nil }
    }

    private func startPolling(_ kind: PermissionKind) {
        waitingFor = kind
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Give up quietly after 5 minutes; the inline prompts stay as a reminder.
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh(kind)
                if self.isGranted(kind) { return }
            }
            self?.cancelRequest()
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        waitingFor = nil
    }

    private func granted(_ kind: PermissionKind) {
        statuses[kind] = .granted
        if waitingFor == kind { stopPolling() }
        let callbacks = completions[kind] ?? []
        completions[kind] = nil
        guard helper != nil, helperState.kind == kind else {
            callbacks.forEach { $0() }
            return
        }
        helperState.granted = true
        // Let the checkmark land, then tidy up and come back to Mac Vitals.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            self?.closeHelper()
            NSApp.activate()
            callbacks.forEach { $0() }
        }
    }

    /// App Management can't be detected, so the helper offers "Done" and the next uninstall
    /// confirms it for real.
    private func confirmManually(_ kind: PermissionKind) {
        if kind == .appManagement { UserDefaults.standard.set(true, forKey: Self.learnedAppManagementKey) }
        granted(kind)
    }

    // MARK: Floating helper

    @Observable
    final class HelperState {
        var kind: PermissionKind = .fullDiskAccess
        var granted = false
        var detectsAutomatically = true
    }

    private func showHelper(for kind: PermissionKind) {
        closeHelper()
        helperState.kind = kind
        helperState.granted = false
        // App Management can't be detected, so it gets a "Done" button; the others are watched.
        helperState.detectsAutomatically = kind != .appManagement
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: PermissionHelperView(
            state: helperState,
            onCancel: { [weak self] in self?.cancelRequest() },
            onDone: { [weak self] in self?.confirmManually(kind) }
        ))
        // Bottom-center of the screen: next to System Settings, out of the way of its list.
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - 190, y: screen.minY + 40))
        }
        panel.orderFrontRegardless()
        helper = panel
    }

    private func closeHelper() {
        helper?.close()
        helper = nil
    }
}

/// Owns the CLLocationManager (it must live on the main thread) and reports changes.
/// We never start location updates: authorization alone lets CoreWLAN return the network name.
private final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        super.init()
        manager.delegate = self
    }

    var status: PermissionStatus {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        default: .granted
        }
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let onChange = onChange
        Task { @MainActor in onChange() }
    }
}

/// The floating "drag me into the list" helper shown beside System Settings.
private struct PermissionHelperView: View {
    let state: Permissions.HelperState
    let onCancel: () -> Void
    let onDone: () -> Void
    @State private var nudge = false

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if state.granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .offset(y: nudge ? -4 : 0)
                        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                        .pointerStyle(.grabIdle)
                        .help("Drag into the \(state.kind.systemName) list")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 70, height: 70)

            VStack(alignment: .leading, spacing: 4) {
                if state.granted {
                    Text("Access granted").font(.headline)
                    Text("Taking you back to Mac Vitals…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Drag Mac Vitals into the list")
                        .font(.headline)
                    Text(state.detectsAutomatically
                         ? "Or click + under \(state.kind.systemName) and choose Mac Vitals. We'll notice as soon as it's on."
                         : "Or click + under \(state.kind.systemName) and choose Mac Vitals, then click Done.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if !state.detectsAutomatically {
                            Button("Done", action: onDone)
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                                .pointerStyle(.link)
                        }
                        Button("Not now", action: onCancel)
                            .buttonStyle(.link)
                            .font(.caption)
                            .pointerStyle(.link)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 380)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: state.granted)
        .onAppear {
            // A few bobs to catch the eye, then still (a forever animation keeps SwiftUI redrawing
            // every frame for as long as the helper is open).
            withAnimation(.easeInOut(duration: 0.9).repeatCount(5, autoreverses: true)) { nudge = true }
        }
    }
}
