import AppKit
import SwiftUI
import Observation

/// Permission handling modeled on the best Mac apps (CleanMyMac, DaisyDisk, Bartender):
/// explain first, ask in context, take people to the exact setting with a drag-and-drop helper,
/// and detect the grant automatically so nobody has to click "I did it".
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var hasFullDiskAccess = Permissions.checkFullDiskAccess()
    private(set) var isWaitingForFullDiskAccess = false
    /// Called once when Full Disk Access is detected after we asked for it.
    @ObservationIgnored var onFullDiskAccessGranted: (() -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var helper: NSPanel?

    // MARK: Detection

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

    func refresh() {
        hasFullDiskAccess = Self.checkFullDiskAccess()
    }

    // MARK: Full Disk Access flow

    /// Opens System Settings at Full Disk Access, shows the floating drag helper, and watches
    /// for the grant. When it lands: checkmark, helper closes, Mac Vitals comes back to the front.
    func requestFullDiskAccess() {
        refresh()
        guard !hasFullDiskAccess else {
            onFullDiskAccessGranted?()
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        showHelper()
        startPolling()
    }

    func cancelFullDiskAccessRequest() {
        stopPolling()
        closeHelper()
    }

    private func startPolling() {
        isWaitingForFullDiskAccess = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Give up quietly after 5 minutes; the inline "Needs access" row stays as a reminder.
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if Permissions.checkFullDiskAccess() {
                    self.granted()
                    return
                }
            }
            self?.cancelFullDiskAccessRequest()
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isWaitingForFullDiskAccess = false
    }

    private func granted() {
        hasFullDiskAccess = true
        stopPolling()
        helperState.granted = true
        // Let the checkmark land, then tidy up and come back to Mac Vitals.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            self?.closeHelper()
            NSApp.activate()
            self?.onFullDiskAccessGranted?()
        }
    }

    // MARK: Floating helper

    @ObservationIgnored private let helperState = HelperState()

    @Observable
    final class HelperState {
        var granted = false
    }

    private func showHelper() {
        closeHelper()
        helperState.granted = false
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
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
        panel.contentView = NSHostingView(rootView: PermissionHelperView(state: helperState) { [weak self] in
            self?.cancelFullDiskAccessRequest()
        })
        // Bottom-center of the screen: next to System Settings, out of the way of its list.
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - 180, y: screen.minY + 40))
        }
        panel.orderFrontRegardless()
        helper = panel
    }

    private func closeHelper() {
        helper?.close()
        helper = nil
    }
}

/// The floating "drag me into the list" helper shown beside System Settings.
private struct PermissionHelperView: View {
    let state: Permissions.HelperState
    let onCancel: () -> Void
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
                        .help("Drag into the Full Disk Access list")
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
                    Text("Or click + in System Settings and choose Mac Vitals. We'll notice as soon as it's on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Not now", action: onCancel)
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: state.granted)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { nudge = true }
        }
    }
}
