import AppKit
import SwiftUI

/// Mac Vitals lives in the menu bar. The Dock icon (and app menu) only appear while one of
/// its windows is open, the way most menu bar utilities behave. Minimized windows still count
/// as open so they can be restored from the Dock.
@MainActor
enum DockIcon {
    private static var openWindows: Set<String> = []

    static func windowOpened(_ id: String) {
        openWindows.insert(id)
        update()
        bringWindowsForward()
    }

    static func windowClosed(_ id: String) {
        openWindows.remove(id)
        update()
    }

    private static func update() {
        let policy: NSApplication.ActivationPolicy = openWindows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// Menu bar apps aren't activated by macOS when they launch or open a window, so a newly
    /// opened window lands *behind* the app you're using. Explicitly activate and raise it.
    /// (Deferred one runloop so the window exists and the policy change has taken effect.)
    static func bringWindowsForward() {
        DispatchQueue.main.async {
            NSApp.activate()
            for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}

extension Notification.Name {
    /// Posted when the app is launched again while already running (Finder, Spotlight, Launchpad).
    static let openDashboard = Notification.Name("MacVitals.openDashboard")
}

extension View {
    /// Shows the Dock icon while this window is open.
    func showsDockIconWhileOpen(_ id: String) -> some View {
        onAppear { DockIcon.windowOpened(id) }
            .onDisappear { DockIcon.windowClosed(id) }
    }
}
