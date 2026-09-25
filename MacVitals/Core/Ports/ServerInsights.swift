import Foundation
import Darwin

/// Plain-language readings for listening servers: what each one *is* (Vite, Postgres, AirPlay…),
/// which project it belongs to, whether it's idle, and whether other devices can reach it.
enum ServerInsights {
    // MARK: What is it?

    struct Tech: Equatable, Sendable {
        let name: String
        let symbol: String
    }

    /// Recognizes common dev servers and databases from the process and its arguments,
    /// falling back to well-known ports.
    static func tech(command: String, arguments: [String], port: Int) -> Tech? {
        let joined = arguments.joined(separator: " ").lowercased()
        let cmd = command.lowercased()

        let byArgument: [(needle: String, tech: Tech)] = [
            ("next dev", Tech(name: "Next.js", symbol: "n.circle")), ("next-server", Tech(name: "Next.js", symbol: "n.circle")),
            ("/next/", Tech(name: "Next.js", symbol: "n.circle")),
            ("vite", Tech(name: "Vite", symbol: "bolt")),
            ("astro", Tech(name: "Astro", symbol: "sparkles")),
            ("nuxt", Tech(name: "Nuxt", symbol: "triangle")),
            ("remix", Tech(name: "Remix", symbol: "r.circle")),
            ("svelte-kit", Tech(name: "SvelteKit", symbol: "s.circle")),
            ("storybook", Tech(name: "Storybook", symbol: "book")),
            ("webpack", Tech(name: "Webpack", symbol: "cube")),
            ("react-scripts", Tech(name: "Create React App", symbol: "atom")),
            ("metro", Tech(name: "Metro (React Native)", symbol: "iphone")),
            ("expo", Tech(name: "Expo", symbol: "iphone")),
            ("gatsby", Tech(name: "Gatsby", symbol: "g.circle")),
            ("ng serve", Tech(name: "Angular", symbol: "a.circle")),
            ("manage.py runserver", Tech(name: "Django", symbol: "d.circle")),
            ("uvicorn", Tech(name: "Uvicorn (FastAPI)", symbol: "hare")),
            ("gunicorn", Tech(name: "Gunicorn", symbol: "g.circle")),
            ("flask", Tech(name: "Flask", symbol: "flask")),
            ("http.server", Tech(name: "Python file server", symbol: "folder")),
            ("jupyter", Tech(name: "Jupyter", symbol: "book.pages")),
            ("puma", Tech(name: "Rails (Puma)", symbol: "tram")), ("rails", Tech(name: "Rails", symbol: "tram")),
            ("jekyll", Tech(name: "Jekyll", symbol: "doc.richtext")),
            ("hugo", Tech(name: "Hugo", symbol: "doc.richtext")),
            ("wrangler", Tech(name: "Cloudflare Wrangler", symbol: "cloud")),
            ("convex", Tech(name: "Convex", symbol: "cloud")),
            ("supabase", Tech(name: "Supabase", symbol: "cylinder.split.1x2")),
        ]
        for entry in byArgument where joined.contains(entry.needle) { return entry.tech }

        let byCommand: [(prefix: String, tech: Tech)] = [
            ("postgres", Tech(name: "PostgreSQL", symbol: "cylinder.split.1x2")),
            ("redis", Tech(name: "Redis", symbol: "cylinder")),
            ("mysqld", Tech(name: "MySQL", symbol: "cylinder.split.1x2")),
            ("mongod", Tech(name: "MongoDB", symbol: "leaf")),
            ("ollama", Tech(name: "Ollama", symbol: "brain")),
            ("com.docker", Tech(name: "Docker", symbol: "shippingbox")), ("docker", Tech(name: "Docker", symbol: "shippingbox")),
            ("vpnkit", Tech(name: "Docker", symbol: "shippingbox")),
            ("bun", Tech(name: "Bun", symbol: "circle.hexagongrid")),
            ("deno", Tech(name: "Deno", symbol: "circle.hexagongrid")),
            ("node", Tech(name: "Node.js", symbol: "circle.hexagongrid")),
            ("python", Tech(name: "Python", symbol: "chevron.left.forwardslash.chevron.right")),
            ("ruby", Tech(name: "Ruby", symbol: "diamond")),
            ("php", Tech(name: "PHP", symbol: "chevron.left.forwardslash.chevron.right")),
            ("java", Tech(name: "Java", symbol: "cup.and.saucer")),
            ("caddy", Tech(name: "Caddy", symbol: "server.rack")),
            ("nginx", Tech(name: "nginx", symbol: "server.rack")),
            ("httpd", Tech(name: "Apache", symbol: "server.rack")),
        ]
        for entry in byCommand where cmd.hasPrefix(entry.prefix) { return entry.tech }

        let byPort: [Int: Tech] = [
            5432: Tech(name: "PostgreSQL", symbol: "cylinder.split.1x2"),
            6379: Tech(name: "Redis", symbol: "cylinder"),
            3306: Tech(name: "MySQL", symbol: "cylinder.split.1x2"),
            27017: Tech(name: "MongoDB", symbol: "leaf"),
            11434: Tech(name: "Ollama", symbol: "brain"),
            8888: Tech(name: "Jupyter", symbol: "book.pages"),
        ]
        return byPort[port]
    }

    // MARK: macOS and app services (for non-developers)

    struct Service: Equatable, Sendable {
        let name: String
        let explanation: String
        /// Where to turn it off, if people might want to.
        let settingsHint: String?
    }

    static func service(command: String, port: Int) -> Service? {
        switch (command, port) {
        case ("ControlCenter", 5000), ("ControlCenter", 7000), ("AirPlayXPCHelper", _):
            return Service(name: "AirPlay Receiver",
                           explanation: "Lets your iPhone or other Macs stream video and audio to this Mac.",
                           settingsHint: "System Settings › General › AirDrop & Handoff › AirPlay Receiver")
        case ("rapportd", _):
            return Service(name: "Continuity", explanation: "Lets your Apple devices find each other for Handoff, Universal Clipboard and AirDrop.", settingsHint: nil)
        case ("sharingd", _):
            return Service(name: "AirDrop & Sharing", explanation: "Handles AirDrop and sharing between your devices.", settingsHint: nil)
        case (_, 22), ("sshd", _):
            return Service(name: "Remote Login (SSH)", explanation: "Lets other computers log in to this Mac from the command line.",
                           settingsHint: "System Settings › General › Sharing › Remote Login")
        case (_, 5900), ("screensharingd", _):
            return Service(name: "Screen Sharing", explanation: "Lets other computers view and control this Mac's screen.",
                           settingsHint: "System Settings › General › Sharing › Screen Sharing")
        case (_, 445), ("smbd", _):
            return Service(name: "File Sharing", explanation: "Shares folders from this Mac with other computers.",
                           settingsHint: "System Settings › General › Sharing › File Sharing")
        case (_, 631), ("cupsd", _):
            return Service(name: "Printer Sharing", explanation: "Shares printers connected to this Mac.",
                           settingsHint: "System Settings › General › Sharing › Printer Sharing")
        case ("cloudflared", _):
            return Service(name: "Cloudflare Tunnel",
                           explanation: "Can make a server on this Mac reachable from the internet, not just your Wi-Fi. Make sure you meant to leave it running.",
                           settingsHint: nil)
        case ("ollama", _):
            return Service(name: "Ollama", explanation: "Runs AI models locally. Apps on this Mac talk to it on port 11434.", settingsHint: nil)
        case ("mediasharingd", _):
            return Service(name: "Media Sharing", explanation: "Shares your Music library or Home Sharing with other devices on your network.",
                           settingsHint: "System Settings › General › Sharing › Media Sharing")
        case (let c, _) where c.hasPrefix("Spotify"):
            return Service(name: "Spotify Connect", explanation: "Lets Spotify on other devices control playback here.", settingsHint: nil)
        case (let c, _) where c.hasPrefix("Dropbox"):
            return Service(name: "Dropbox LAN Sync", explanation: "Syncs Dropbox files directly with other computers on your network.", settingsHint: nil)
        case (let c, _) where c.hasPrefix("figma_agent"):
            return Service(name: "Figma font helper", explanation: "Lets figma.com use fonts installed on this Mac.", settingsHint: nil)
        case (let c, _) where c.hasPrefix("Code Helper") || c == "Electron":
            return Service(name: "Editor helper", explanation: "Part of your code editor (extensions, debugging, previews).", settingsHint: nil)
        default:
            return nil
        }
    }

    // MARK: Idle, uptime, exposure

    /// Running for a while and doing nothing right now: probably forgotten.
    static let idleMinimumUptime: TimeInterval = 30 * 60

    static func isIdle(cpu: Double, uptime: TimeInterval?) -> Bool {
        cpu < 0.5 && (uptime ?? 0) >= idleMinimumUptime
    }

    static func describeUptime(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "just started"
        case ..<3600: "\(Int(seconds / 60)) min"
        case ..<86_400: "\(Int(seconds / 3600)) h"
        default: "\(Int(seconds / 86_400)) day\(seconds >= 2 * 86_400 ? "s" : "")"
        }
    }

    // MARK: Other services

    /// One entry per process, however many ports it listens on (AirPlay uses both 5000 and 7000).
    struct ServiceGroup: Identifiable, Sendable {
        let pid: pid_t
        let ports: [ListeningPort]
        var id: pid_t { pid }
        var primary: ListeningPort { ports[0] }
        var name: String { primary.service?.name ?? primary.tech?.name ?? primary.command }
        var portList: String { ports.map { ":\($0.port)" }.joined(separator: " · ") }
        var isLocalOnly: Bool { ports.allSatisfy(\.isLocalOnly) }
    }

    static func serviceGroups(_ ports: [ListeningPort]) -> [ServiceGroup] {
        Dictionary(grouping: ports.filter { !$0.isDevServer }, by: \.pid)
            .map { pid, ports in ServiceGroup(pid: pid, ports: ports.sorted { $0.port < $1.port }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Projects

    struct Project: Identifiable, Sendable {
        let folder: String
        let name: String
        let servers: [ListeningPort]
        var id: String { folder }
    }

    /// Dev servers grouped by the folder they were started from.
    static func projects(_ ports: [ListeningPort]) -> [Project] {
        let grouped = Dictionary(grouping: ports.filter(\.isDevServer)) { $0.workingDirectory ?? "" }
        return grouped.map { folder, servers in
            Project(folder: folder, name: (folder as NSString).lastPathComponent,
                    servers: servers.sorted { $0.port < $1.port })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Process details (command line, start time)

enum ProcessDetails {
    /// Full command-line arguments via KERN_PROCARGS2. Works for your own processes, no permissions.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Layout: argc (Int32), executable path, NUL padding, then argc NUL-terminated strings.
    static func parseProcArgs(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > 4 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = 4
        while index < buffer.count, buffer[index] != 0 { index += 1 } // executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 } // padding
        var args: [String] = []
        while args.count < Int(argc), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
