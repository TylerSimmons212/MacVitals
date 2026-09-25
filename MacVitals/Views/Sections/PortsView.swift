import SwiftUI
import AppKit

/// Dev Servers page. For developers: what's running for which project, what it is (Vite,
/// Postgres…), what's idle and forgotten, and "what's using port 3000?". For everyone: which
/// parts of macOS and apps accept connections, in plain words. Under the hood: full details.
struct PortsView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var model = PortsModel()
    @State private var pendingStop: [ListeningPort] = []
    @State private var portQuery = ""

    private func cpu(_ port: ListeningPort) -> Double { monitor.process(pid: port.pid)?.cpu ?? 0 }
    private func memory(_ port: ListeningPort) -> UInt64 { monitor.process(pid: port.pid)?.memory ?? 0 }
    private func isIdle(_ port: ListeningPort) -> Bool { ServerInsights.isIdle(cpu: cpu(port), uptime: port.uptime) }

    private var devServers: [ListeningPort] { model.ports.filter(\.isDevServer) }
    private var idleServers: [ListeningPort] { devServers.filter(isIdle) }
    private var exposedDevServers: [ListeningPort] { devServers.filter { !$0.isLocalOnly } }

    var body: some View {
        SectionScroll {
            verdict.entrance()
            stats.entrance(delay: 0.04)
            portLookup.entrance(delay: 0.06)
            if !idleServers.isEmpty { idleCleanup.entrance(delay: 0.08) }
            projects.entrance(delay: 0.1)

            underTheHoodHeader
            otherServices
        }
        .task {
            // Refresh every 5 seconds while this page is on screen.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.ports.map(\.id))
        .confirmationDialog(stopTitle, isPresented: Binding(get: { !pendingStop.isEmpty }, set: { if !$0 { pendingStop = [] } })) {
            Button(pendingStop.count == 1 ? "Stop Server" : "Stop \(pendingStop.count) Servers", role: .destructive) {
                let pids = Set(pendingStop.map(\.pid))
                pids.forEach { ProcessController.signal($0, force: false) }
                pendingStop = []
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    await model.refresh()
                }
            }
        } message: {
            Text("Sends a normal shutdown signal, like pressing Ctrl-C in the terminal that started it.")
        }
    }

    private var stopTitle: String {
        guard let first = pendingStop.first else { return "" }
        if pendingStop.count == 1 { return "Stop \(first.tech?.name ?? first.command) on port \(first.port)?" }
        return "Stop \(pendingStop.count) idle servers?"
    }

    // MARK: Verdict

    private var verdict: some View {
        let count = devServers.count
        let idle = idleServers.count
        let exposed = exposedDevServers.count
        let tint: Color = exposed > 0 ? .orange : (idle > 0 ? .yellow : (count > 0 ? .green : .secondary))
        let title: String = switch count {
        case 0: "No dev servers running"
        case 1: "1 dev server running"
        default: "\(count) dev servers running"
        }
        let sentence: String = {
            if exposed > 0 {
                return "\(exposed) \(exposed == 1 ? "is" : "are") reachable by other devices on your network, not just this Mac. Fine at home; risky on public Wi-Fi."
            }
            if idle > 0 {
                return "\(idle) \(idle == 1 ? "has" : "have") been idle for a while, probably forgotten. Stopping them frees memory."
            }
            if count > 0 { return "Everything running is busy and only reachable from this Mac." }
            return "Local servers you start (npm run dev, rails s, docker…) show up here, grouped by project."
        }()

        return HStack(spacing: 22) {
            ZStack {
                GaugeRing(fraction: count == 0 ? 0 : Double(count - idle) / Double(count), color: tint, lineWidth: 12)
                VStack(spacing: 0) {
                    RollingText("\(count)", size: 30)
                    Text(count == 1 ? "server" : "servers").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.weight(.semibold)).contentTransition(.interpolate)
                Text(sentence).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.hasLoaded {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    // MARK: Stats

    private var stats: some View {
        let idleMemory = idleServers.reduce(UInt64(0)) { $0 + memory($1) }
        let totalMemory = Set(devServers.map(\.pid)).reduce(UInt64(0)) { total, pid in
            total + (monitor.process(pid: pid)?.memory ?? 0)
        }
        return HStack(spacing: 16) {
            DetailStat(label: "Projects", term: "Folders",
                       value: "\(ServerInsights.projects(model.ports).count)",
                       caption: "\(devServers.count) server\(devServers.count == 1 ? "" : "s") total")
            DetailStat(label: "Idle", term: "Forgotten",
                       value: "\(idleServers.count)",
                       tint: idleServers.isEmpty ? nil : .yellow,
                       caption: idleServers.isEmpty ? "Nothing forgotten" : "Holding \(Fmt.memory(idleMemory))",
                       help: "Running for 30+ minutes and doing nothing right now.")
            DetailStat(label: "On your network", term: "0.0.0.0",
                       value: "\(exposedDevServers.count)",
                       tint: exposedDevServers.isEmpty ? nil : .orange,
                       caption: exposedDevServers.isEmpty ? "All local to this Mac" : "Reachable by other devices",
                       help: "Servers bound to all interfaces (0.0.0.0 / *) can be reached by anyone on your Wi-Fi. Bind to 127.0.0.1 to keep them private.")
            DetailStat(label: "Memory", term: "RSS",
                       value: Fmt.memory(totalMemory),
                       caption: "Used by all dev servers")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Port lookup

    private var portLookup: some View {
        let trimmed = portQuery.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        let port = Int(trimmed)
        let matches = port.map { p in model.ports.filter { $0.port == p } } ?? []
        return Card("What's using a port?", systemImage: "magnifyingglass", tint: Theme.network) {
            HStack(spacing: 12) {
                TextField("Port, e.g. 3000", text: $portQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .monospacedDigit()
                if let port {
                    if matches.isEmpty {
                        Label("Nothing is using port \(port). It's free.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(matches) { match in
                            HStack(spacing: 8) {
                                Image(systemName: match.tech?.symbol ?? "server.rack").foregroundStyle(Theme.network)
                                Text("\(match.tech?.name ?? match.command)").font(.callout.weight(.semibold))
                                Text(match.projectName.map { "in \($0)" } ?? "PID \(match.pid)")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Stop") { pendingStop = [match] }
                                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                            }
                        }
                    }
                } else {
                    Text("Got \"address already in use\"? Type the port to see what's holding it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Idle cleanup

    private var idleCleanup: some View {
        let idleMemory = idleServers.reduce(UInt64(0)) { $0 + memory($1) }
        return HStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill").font(.title2).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(idleServers.count) idle server\(idleServers.count == 1 ? " is" : "s are") holding \(Fmt.memory(idleMemory))")
                    .font(.headline)
                Text(idleServers.prefix(3).map { ":\($0.port) \($0.projectName ?? $0.command)" }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                pendingStop = idleServers
            } label: {
                Label("Stop all idle", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)
            .pointerStyle(.link)
        }
        .cardStyle(padding: 16, tint: .yellow)
    }

    // MARK: Projects

    private var projects: some View {
        let groups = ServerInsights.projects(model.ports)
        return VStack(alignment: .leading, spacing: 16) {
            if groups.isEmpty && model.hasLoaded {
                ContentUnavailableView("No dev servers running",
                                       systemImage: "server.rack",
                                       description: Text("Start one (npm run dev, rails s, python -m http.server…) and it'll appear here, grouped by project."))
                    .frame(maxWidth: .infinity, minHeight: 200) // fill the card so it's centered
                    .cardStyle()
            }
            ForEach(groups) { project in
                ProjectCard(
                    project: project,
                    cpu: cpu, memory: memory, isIdle: isIdle,
                    onStop: { pendingStop = $0 }
                )
            }
        }
    }

    // MARK: Under the hood

    private var underTheHoodHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Other things accepting connections").font(.title3.weight(.semibold))
            Text("Parts of macOS and your apps that listen for connections, explained. Technical details are on each row.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    /// A single grouped list (like System Settings): rows separated by dividers inside one card,
    /// so they read as one list and can never fuse together like separate glass cards.
    private var otherServices: some View {
        let groups = ServerInsights.serviceGroups(model.ports)
        return VStack(spacing: 0) {
            if groups.isEmpty && model.hasLoaded {
                Text("Nothing else is listening.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { Divider().padding(.leading, 56) }
                ServiceRow(group: group, bundlePath: owningApp(group.pid)?.bundlePath)
            }
        }
        .cardStyle(padding: 6)
    }

    private func owningApp(_ pid: pid_t) -> AppUsage? {
        monitor.apps.first { app in app.kind == .application && app.processes.contains { $0.pid == pid } }
    }
}

// MARK: - Project card

private struct ProjectCard: View {
    let project: ServerInsights.Project
    let cpu: (ListeningPort) -> Double
    let memory: (ListeningPort) -> UInt64
    let isIdle: (ListeningPort) -> Bool
    let onStop: ([ListeningPort]) -> Void

    var body: some View {
        let techs = Array(Set(project.servers.compactMap { $0.tech?.name })).sorted()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.network.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.headline)
                    Text(abbreviate(project.folder)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                ForEach(techs, id: \.self) { tech in
                    Text(tech).font(.caption.weight(.medium)).glassChip()
                }
                Spacer()
                HStack(spacing: 6) {
                    if let editor = EditorLauncher.preferred {
                        Button { EditorLauncher.open(project.folder, in: editor) } label: {
                            Label("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        .help("Open this project in \(editor.name)")
                    }
                    Button { EditorLauncher.openTerminal(at: project.folder) } label: { Image(systemName: "terminal") }
                        .help("Open Terminal here")
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: project.folder)) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                    if project.servers.count > 1 {
                        Button(role: .destructive) { onStop(project.servers) } label: { Label("Stop all", systemImage: "stop.fill") }
                            .help("Stop every server in this project")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .pointerStyle(.link)
            }
            VStack(spacing: 4) {
                ForEach(project.servers) { server in
                    ServerRow(server: server, cpu: cpu(server), memory: memory(server), idle: isIdle(server)) { onStop([server]) }
                }
            }
        }
        .cardStyle(padding: 16, tint: Theme.network)
    }

    private func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

private struct ServerRow: View {
    let server: ListeningPort
    let cpu: Double
    let memory: UInt64
    let idle: Bool
    let onStop: () -> Void
    @State private var hovering = false
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(verbatim: ":\(server.port)")
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.network)
                    .frame(minWidth: 76, alignment: .leading)
                Image(systemName: server.tech?.symbol ?? "server.rack").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(server.tech?.name ?? server.command).font(.body.weight(.medium))
                        if idle { Text("Idle").font(.caption2.weight(.semibold)).glassChip(tint: .yellow) }
                        if !server.isLocalOnly {
                            Label("On your network", systemImage: "globe")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .help("Other devices on your Wi-Fi can reach this. Bind to 127.0.0.1 (localhost) to keep it private.")
                        }
                    }
                    Text(server.uptime.map { "Running \(ServerInsights.describeUptime($0))" } ?? server.command)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.percent(cpu, digits: 1)).font(.callout).monospacedDigit()
                    Text(Fmt.memory(memory)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Button {
                        if let url = URL(string: "http://localhost:\(server.port)") { NSWorkspace.shared.open(url) }
                    } label: { Image(systemName: "safari") }
                        .help("Open http://localhost:\(server.port)")
                    Button { withAnimation(.spring(response: 0.35)) { showDetails.toggle() } } label: {
                        Image(systemName: "info.circle")
                    }
                    .help("Technical details")
                    Button(role: .destructive, action: onStop) { Image(systemName: "stop.fill") }
                        .help("Stop this server")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .pointerStyle(.link)
            }
            if showDetails {
                TechnicalDetails(port: server).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }
}

// MARK: - Other services

private struct ServiceRow: View {
    let group: ServerInsights.ServiceGroup
    /// The app that owns this process, for its real icon.
    let bundlePath: String?
    @State private var showDetails = false
    @State private var hovering = false

    var body: some View {
        let service = group.primary.service
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if service != nil {
                        Image(systemName: "apple.logo").font(.title3).foregroundStyle(.secondary)
                    } else if let bundlePath {
                        AppIconView(bundlePath: bundlePath, kind: .application, size: 26)
                    } else {
                        Image(systemName: "app.connected.to.app.below.fill").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 30, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.name).font(.body.weight(.medium))
                        if group.primary.command != group.name {
                            Text(group.primary.command).font(.caption).foregroundStyle(.tertiary)
                        }
                        Text(verbatim: group.portList).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if !group.isLocalOnly {
                            Label("On your network", systemImage: "globe").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Text(service?.explanation ?? "An app accepting connections. Usually fine if you recognize the app.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let hint = service?.settingsHint {
                        Label("Turn off in \(hint)", systemImage: "gearshape")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button { withAnimation(.spring(response: 0.35)) { showDetails.toggle() } } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                    .help("Technical details")
            }
            if showDetails {
                TechnicalDetails(ports: group.ports, indent: 42)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }
}

/// The under-the-hood view of one listening process (one or more ports).
private struct TechnicalDetails: View {
    let ports: [ListeningPort]
    var indent: CGFloat = 88

    init(port: ListeningPort, indent: CGFloat = 88) {
        self.ports = [port]
        self.indent = indent
    }

    init(ports: [ListeningPort], indent: CGFloat = 88) {
        self.ports = ports
        self.indent = indent
    }

    var body: some View {
        let port = ports[0]
        VStack(alignment: .leading, spacing: 4) {
            detail("Command", port.commandLine)
            detail("Process", "\(port.command) · PID \(port.pid)")
            detail("Listening on", ports.flatMap { p in p.addresses.map { "\($0):\(p.port)" } }.joined(separator: ", "))
            if let start = port.startDate {
                detail("Started", start.formatted(date: .abbreviated, time: .shortened))
            }
            if let cwd = port.workingDirectory { detail("Folder", cwd) }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .padding(.leading, indent)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
        }
    }
}

// MARK: - Editors

enum EditorLauncher {
    struct Editor: Equatable {
        let name: String
        let url: URL
    }

    /// First installed editor, in order of how common they are for web/dev-server work.
    static let preferred: Editor? = {
        let candidates = [
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
            ("VS Code", "com.microsoft.VSCode"),
            ("Zed", "dev.zed.Zed"),
            ("Windsurf", "com.exafunction.windsurf"),
            ("Xcode", "com.apple.dt.Xcode"),
        ]
        for (name, bundleID) in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return Editor(name: name, url: url)
            }
        }
        return nil
    }()

    static func open(_ folder: String, in editor: Editor) {
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openTerminal(at folder: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
