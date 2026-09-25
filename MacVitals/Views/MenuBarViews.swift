import SwiftUI
import AppKit
import Combine

// MARK: - Status item icon

/// The menu bar icon: one static glyph, plus a colored dot when something needs attention.
/// Reads only `monitor.attention`, which changes rarely, so the status item almost never redraws.
struct MenuBarLabel: View {
    let monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: monitor.attention))
            .accessibilityLabel(accessibilityText)
            .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
                openWindow(id: WindowID.dashboard)
                NSApp.activate()
            }
    }

    private var accessibilityText: String {
        switch monitor.attention {
        case .none: "Mac Vitals"
        case .warning: "Mac Vitals: needs attention"
        case .critical: "Mac Vitals: critical issue"
        }
    }
}

enum MenuBarIcon {
    @MainActor private static var cache: [Attention: NSImage] = [:]

    @MainActor
    static func image(for attention: Attention) -> NSImage {
        if let cached = cache[attention] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let glyph = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Mac Vitals")?
            .withSymbolConfiguration(config) else { return NSImage() }

        let image: NSImage
        switch attention {
        case .none:
            // Template image: macOS tints it to match the menu bar automatically.
            glyph.isTemplate = true
            image = glyph
        case .warning, .critical:
            let dotColor: NSColor = attention == .critical ? .systemRed : .systemOrange
            let size = NSSize(width: glyph.size.width + 3, height: max(glyph.size.height, 16))
            // Drawing handler runs at draw time, so labelColor resolves for light/dark menu bars.
            image = NSImage(size: size, flipped: false) { rect in
                let glyphRect = NSRect(x: 0, y: (rect.height - glyph.size.height) / 2,
                                       width: glyph.size.width, height: glyph.size.height)
                glyph.draw(in: glyphRect)
                NSColor.labelColor.set()
                glyphRect.fill(using: .sourceAtop)
                // Knock out a ring around the dot so it reads against the glyph.
                let dot = NSRect(x: rect.width - 7, y: rect.height - 7.5, width: 7, height: 7)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                dotColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
                return true
            }
            image.isTemplate = false
        }
        cache[attention] = image
        return image
    }
}

// MARK: - Panel

/// Glanceable status + quick actions. Deliberately not a mini dashboard:
/// no charts, no scrolling, nothing longer than three rows.
struct MenuBarPanel: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Router.self) private var router
    @Environment(CleanupEngine.self) private var cleanup
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isVisible = false
    @State private var ports = PortsModel()
    /// While the pointer is over the app list (or a quit is being confirmed), its order is
    /// frozen so rows can't shuffle under the cursor and you can't quit the wrong app.
    @State private var hoveringApps = false
    @State private var frozenAppIDs: [String]?
    @State private var confirmingQuitID: String?

    var body: some View {
        // SwiftUI keeps this panel alive while it's closed; render nothing (and observe
        // nothing) until it's actually on screen.
        Group {
            if isVisible {
                content
            } else {
                Color.clear.frame(width: 340, height: 420)
            }
        }
        .tracksVisibility(as: "menuBarPanel", monitor: monitor, isVisible: $isVisible)
        .task(id: isVisible) {
            if isVisible { await ports.refresh() }
        }
    }

    private var content: some View {
        let actionable = monitor.health.issues.filter { $0.severity >= .warning }
        // spacing = merge distance, not a gap; 0 keeps each panel section a separate piece of glass.
        return GlassEffectContainer(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                statusHeader
                if !actionable.isEmpty {
                    attention(Array(actionable.prefix(3)))
                }
                gauges
                heaviestApps
                shortcuts
                footer
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: Sections

    private var statusHeader: some View {
        let tint = Theme.health(monitor.health.score)
        return Button { open(.overview) } label: {
            HStack(spacing: 12) {
                HealthRing(score: monitor.health.score, lineWidth: 5, showsLabel: false)
                    .overlay(
                        Text("\(monitor.health.score)")
                            .font(.system(.callout, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .rollingNumber(monitor.health.score)
                    )
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(monitor.health.grade).font(.headline).foregroundStyle(tint)
                    Text(headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
            .glassEffect(.regular.tint(tint.opacity(0.12)).interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    private var headline: String {
        if monitor.health.issues.contains(where: { $0.severity >= .warning }) {
            return "Needs your attention"
        }
        if let info = monitor.health.issues.first {
            return info.title
        }
        return "Everything looks healthy"
    }

    /// One line per issue: what's wrong + how bad. The whole row opens the relevant section;
    /// the full explanation is a hover tooltip (and lives in the main window).
    private func attention(_ issues: [HealthIssue]) -> some View {
        VStack(spacing: 2) {
            ForEach(issues) { issue in
                PanelRow(
                    icon: Theme.severityIcon(issue.severity),
                    tint: Theme.severity(issue.severity),
                    title: issue.compactTitle,
                    value: issue.metric,
                    valueTint: Theme.severity(issue.severity),
                    help: issue.detail
                ) { open(issue.section) }
            }
        }
        .padding(6)
        .glassEffect(.regular.tint(Theme.severity(issues[0].severity).opacity(0.10)), in: .rect(cornerRadius: 16))
    }

    private var gauges: some View {
        HStack(spacing: 0) {
            MiniGauge(label: "CPU", fraction: monitor.cpu.total / 100,
                      text: Fmt.percent(monitor.cpu.total), tint: Theme.cpu) { open(.cpu) }
            MiniGauge(label: "Memory", fraction: monitor.memory.usedPercent / 100,
                      text: Fmt.percent(monitor.memory.usedPercent),
                      tint: monitor.memory.pressure == .normal ? Theme.memory : Theme.pressure(monitor.memory.pressure)) { open(.memory) }
            MiniGauge(label: "Disk", fraction: monitor.disk.usedPercent / 100,
                      text: Fmt.percent(monitor.disk.usedPercent), tint: Theme.disk) { open(.disk) }
            if let battery = monitor.battery {
                MiniGauge(label: battery.isCharging ? "Charging" : "Battery", fraction: battery.percent / 100,
                          text: Fmt.percent(battery.percent),
                          tint: battery.percent < 20 ? .red : Theme.battery) { open(.battery) }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var heaviestApps: some View {
        // Leave out macOS and Mac Vitals itself: this list is for spotting apps you might quit.
        let live = monitor.apps.filter { $0.kind != .system && !$0.isCurrentApp }
        let top: [AppUsage] = if let frozen = frozenAppIDs {
            // Same rows, same order, fresh numbers. Apps that quit drop out.
            frozen.compactMap { id in live.first { $0.id == id } }
        } else {
            Array(live.prefix(3))
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Using the most")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if top.isEmpty {
                Text("Collecting data…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(top) { app in
                HeavyAppRow(
                    app: app,
                    isConfirming: confirmingQuitID == app.id,
                    onRequestQuit: { confirmingQuitID = app.id },
                    onConfirm: {
                        ProcessController.quit(app, force: false)
                        confirmingQuitID = nil
                    },
                    onCancel: { confirmingQuitID = nil }
                )
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveringApps = inside
            if !inside { confirmingQuitID = nil }
            updateFreeze(current: top)
        }
        .onChange(of: confirmingQuitID) { updateFreeze(current: top) }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func updateFreeze(current: [AppUsage]) {
        let shouldFreeze = hoveringApps || confirmingQuitID != nil
        if shouldFreeze, frozenAppIDs == nil {
            frozenAppIDs = current.map(\.id)
        } else if !shouldFreeze {
            frozenAppIDs = nil
        }
    }

    /// Clean Up is always here. Dev servers only surface when some are sitting idle,
    /// so people who don't run dev servers never see it.
    private var shortcuts: some View {
        let idleServers = ports.ports.filter { $0.isDevServer && (monitor.process(pid: $0.pid)?.cpu ?? 0) < 0.5 }
        return VStack(spacing: 2) {
            PanelRow(
                icon: "sparkles",
                tint: Theme.cleanup,
                title: "Clean Up",
                value: cleanup.phase == .ready && cleanup.totalFound > 0
                    ? "\(Fmt.bytes(cleanup.totalFound)) found"
                    : "\(Fmt.bytes(monitor.disk.availableCapacity)) free",
                help: "Scan caches, logs, developer junk and old installers"
            ) { open(.cleanup) }
            if !idleServers.isEmpty {
                PanelRow(
                    icon: "moon.zzz.fill",
                    tint: .yellow,
                    title: idleServers.count == 1 ? "Idle dev server" : "Idle dev servers",
                    value: "\(idleServers.count)",
                    help: idleServers.map { ":\($0.port) \($0.projectName ?? $0.command)" }.joined(separator: "\n")
                ) { open(.ports) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: idleServers.count)
    }

    /// Primary action plus one overflow menu, the common menu bar app pattern
    /// (Dropbox, CleanMyMac, iStat Menus): settings/about/quit are rare, so they don't get buttons.
    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                open(.overview)
            } label: {
                Label("Open Mac Vitals", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .pointerStyle(.link)

            Menu {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                Button("About Mac Vitals") {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Quit Mac Vitals") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .controlSize(.large)
            .fixedSize()
            .pointerStyle(.link)
            .help("More")
        }
    }

    private func open(_ section: DashboardSection) {
        router.section = section
        openWindow(id: WindowID.dashboard)
        NSApp.activate()
    }
}

// MARK: - Pieces

private struct MiniGauge: View {
    let label: String
    let fraction: Double
    let text: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(tint.opacity(0.18), lineWidth: 4.5)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth(duration: 0.6), value: fraction)
                    Text(text)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .rollingNumber(text)
                }
                .frame(width: 46, height: 46)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

/// Top app row with an inline two-step quit (no modal dialogs inside a menu bar panel).
/// Confirmation state lives in the panel, keyed by app ID, so it can never jump to another row.
private struct HeavyAppRow: View {
    let app: AppUsage
    let isConfirming: Bool
    let onRequestQuit: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: 18)
            Text(isConfirming ? "Quit \(app.name)?" : app.name)
                .font(.callout.weight(isConfirming ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if isConfirming {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerStyle(.link)
                    .keyboardShortcut(.cancelAction)
                Button("Quit", role: .destructive, action: onConfirm)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .pointerStyle(.link)
            } else {
                Text("\(Fmt.percent(app.cpu)) · \(Fmt.memory(app.memory))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if ProcessController.canQuit(app) {
                    Button(action: onRequestQuit) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Quit \(app.name)")
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 6)
        .background {
            if hovering || isConfirming {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isConfirming ? Color.red.opacity(0.10) : Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.3), value: isConfirming)
    }
}

/// Standard panel row: icon · label · key value · chevron. The entire row is the click target.
/// Label and value are short by design, so nothing truncates.
private struct PanelRow: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    var valueTint: Color? = nil
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(value)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(valueTint ?? .secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help ?? "")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
