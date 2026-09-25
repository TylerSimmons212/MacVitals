import SwiftUI
import AppKit

/// Reports whether the hosting window is actually visible on screen (not closed, hidden,
/// minimized, or fully covered). SwiftUI keeps hidden MenuBarExtra panels alive, so without
/// this they keep re-rendering on every data update.
struct VisibilityTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onChange: onChange)
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        let closing = note.name == NSWindow.willCloseNotification
                        self?.evaluate(forceHidden: closing)
                    }
                }
            }
            evaluate()
        }

        private func evaluate(forceHidden: Bool = false) {
            guard let window, !forceHidden else {
                report(false)
                return
            }
            report(window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

extension View {
    /// Registers this view's window as a "viewer" of live data while it's on screen.
    func tracksVisibility(as viewer: String, monitor: SystemMonitor, isVisible: Binding<Bool>? = nil) -> some View {
        background(
            VisibilityTracker { visible in
                monitor.setViewer(viewer, visible: visible)
                isVisible?.wrappedValue = visible
            }
            .frame(width: 0, height: 0)
        )
    }
}
