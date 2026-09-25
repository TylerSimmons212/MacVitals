import Foundation

/// The scanning half of each Clean Up module. Pure file-system reads, no side effects,
/// so they can run in parallel and be tested against a fake home folder.
enum JunkScanners {
    static let minimumItemSize: Int64 = 1_000_000

    static func scan(_ module: CleanupModuleKind, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     now: Date = Date()) -> ModuleScan {
        switch module {
        case .systemJunk: systemJunk(home: home)
        case .developerJunk: developerJunk(home: home, now: now)
        case .downloads: downloads(home: home, now: now)
        case .trash: trash(home: home)
        }
    }

    // MARK: System junk

    /// Caches that belong to developer tools are reported under Developer Junk instead.
    static let developerCacheNames: Set<String> = [
        "Homebrew", "pip", "go-build", "CocoaPods", "Yarn", "ms-playwright", "node-gyp", "pnpm",
        "org.swift.swiftpm", "com.apple.dt.Xcode", "JetBrains", "typescript", "deno", "bun",
    ]

    static func systemJunk(home: URL) -> ModuleScan {
        let library = home.appending(path: "Library")
        let ownBundle = Bundle.main.bundleIdentifier ?? "com.tylersimmons.MacVitals"
        let caches = children(of: library.appending(path: "Caches"), tier: .safe) {
            $0 != ownBundle && !developerCacheNames.contains($0)
        }
        let logs = children(of: library.appending(path: "Logs"), tier: .safe)
        return ModuleScan(module: .systemJunk, groups: [
            JunkGroup(id: "app-caches", title: "App caches", icon: "archivebox",
                      explanation: "Temporary files apps keep to open things faster.",
                      afterRemoval: "Apps rebuild them as needed. Some may feel a little slower the first time.",
                      items: caches.items),
            JunkGroup(id: "logs", title: "Logs & crash reports", icon: "doc.text",
                      explanation: "Diagnostic records written by apps and macOS.",
                      afterRemoval: "Nothing changes. New logs are written as needed.",
                      items: logs.items),
        ].filter { !$0.items.isEmpty }, needsAccess: caches.denied || logs.denied)
    }

    // MARK: Developer junk

    static func developerJunk(home: URL, now: Date) -> ModuleScan {
        let library = home.appending(path: "Library")
        let developer = library.appending(path: "Developer")
        var groups: [JunkGroup] = []

        let derived = children(of: developer.appending(path: "Xcode/DerivedData"), tier: .safe) { $0 != "ModuleCache.noindex" }
        groups.append(JunkGroup(
            id: "xcode-derived", title: "Xcode build data", icon: "hammer",
            explanation: "Intermediate build files Xcode keeps for each project (DerivedData).",
            afterRemoval: "Xcode rebuilds it. The next build of each project takes longer.",
            items: derived.items))

        var support = DeviceSupport.classify(children(of: developer.appending(path: "Xcode/iOS DeviceSupport"), tier: .review).items)
        support += DeviceSupport.classify(children(of: developer.appending(path: "Xcode/watchOS DeviceSupport"), tier: .review).items)
        groups.append(JunkGroup(
            id: "device-support", title: "Old device support files", icon: "iphone",
            explanation: "Debug symbols for every iOS/watchOS version you've connected a device with.",
            afterRemoval: "Only needed to debug on that exact version. Xcode re-downloads them when you connect a device.",
            items: support))

        var simulator = fixedItems([developer.appending(path: "CoreSimulator/Caches")], tier: .safe)
        simulator += fixedItems([developer.appending(path: "Xcode/UserData/Previews")], tier: .safe)
        groups.append(JunkGroup(
            id: "simulator-caches", title: "Simulator & preview caches", icon: "ipad.and.iphone",
            explanation: "Cached data for iOS simulators and SwiftUI previews.",
            afterRemoval: "Rebuilt automatically the next time you run a simulator or preview.",
            items: simulator))

        var packageCaches = fixedItems([
            home.appending(path: ".npm/_cacache"),
            home.appending(path: ".bun/install/cache"),
            library.appending(path: "pnpm/store"),
            home.appending(path: ".gradle/caches"),
            home.appending(path: ".cargo/registry/cache"),
        ], tier: .safe)
        packageCaches += children(of: library.appending(path: "Caches"), tier: .safe) { developerCacheNames.contains($0) }.items
        groups.append(JunkGroup(
            id: "package-caches", title: "Package manager caches", icon: "shippingbox",
            explanation: "Downloaded copies of packages (npm, Homebrew, pip, CocoaPods, Cargo…).",
            afterRemoval: "Packages are downloaded again the next time a project needs them.",
            items: packageCaches))

        groups.append(JunkGroup(
            id: "project-dependencies", title: "Dependencies in idle projects", icon: "folder.badge.minus",
            explanation: "node_modules, virtual environments and build folders inside projects you haven't touched in a while.",
            afterRemoval: "Your code isn't touched. Reinstall dependencies when you return to a project (the command is shown for each).",
            items: ProjectJunk.find(home: home, now: now)))

        return ModuleScan(module: .developerJunk, groups: groups.filter { !$0.items.isEmpty })
    }

    // MARK: Downloads

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    static let largeFileThreshold: Int64 = 500_000_000

    static func downloads(home: URL, now: Date) -> ModuleScan {
        let folder = home.appending(path: "Downloads")
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return ModuleScan(module: .downloads, groups: []) }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentAccessDateKey]
        guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return ModuleScan(module: .downloads, groups: [], needsAccess: true)
        }
        var installers: [JunkItem] = []
        var large: [JunkItem] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let lastUsed = [values?.contentAccessDate, values?.contentModificationDate].compactMap { $0 }.max()
            let age = lastUsed.map { now.timeIntervalSince($0) / 86_400 } ?? 0
            let size = CleanupSizing.allocatedSize(of: url)
            let ageText = lastUsed.map { _ in "downloaded \(describeAge(days: age))" }
            if installerExtensions.contains(url.pathExtension.lowercased()) {
                // An installer you downloaded a month ago has almost certainly been installed.
                installers.append(JunkItem(path: url.path, name: url.lastPathComponent, detail: ageText,
                                           size: size, tier: age >= 30 ? .safe : .review))
            } else if size >= largeFileThreshold, age >= 90 {
                large.append(JunkItem(path: url.path, name: url.lastPathComponent,
                                      detail: lastUsed.map { "Last opened \(describeAge(days: now.timeIntervalSince($0) / 86_400))" },
                                      size: size, tier: .review))
            }
        }
        return ModuleScan(module: .downloads, groups: [
            JunkGroup(id: "installers", title: "Installers", icon: "shippingbox.and.arrow.backward",
                      explanation: "Disk images and packages used to install apps.",
                      afterRemoval: "Installed apps keep working. You can download the installer again if you ever need it.",
                      items: sortedBySize(installers)),
            JunkGroup(id: "old-downloads", title: "Big downloads you haven't opened in months", icon: "clock.arrow.circlepath",
                      explanation: "Files over 500 MB in Downloads that haven't been opened in 90+ days.",
                      afterRemoval: "Moved to the Trash first. Put them back if you still need them.",
                      items: sortedBySize(large)),
        ].filter { !$0.items.isEmpty })
    }

    // MARK: Trash

    static func trash(home: URL) -> ModuleScan {
        let result = children(of: home.appending(path: ".Trash"), tier: .careful)
        return ModuleScan(module: .trash, groups: [
            JunkGroup(id: "trash", title: "Items in the Trash", icon: "trash",
                      explanation: "Things you've already thrown away. They still take up space until the Trash is emptied.",
                      afterRemoval: "Deleted permanently. This can't be undone.",
                      items: result.items, isPermanent: true),
        ].filter { !$0.items.isEmpty }, needsAccess: result.denied)
    }

    // MARK: Helpers

    static func children(of directory: URL, tier: SafetyTier, include: (String) -> Bool = { _ in true }) -> (items: [JunkItem], denied: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return ([], false) }
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return ([], true) }
        let items = contents
            .filter { $0.lastPathComponent != ".DS_Store" && include($0.lastPathComponent) }
            .map { JunkItem(path: $0.path, name: $0.lastPathComponent, size: CleanupSizing.allocatedSize(of: $0), tier: tier) }
        return (sortedBySize(items), false)
    }

    static func fixedItems(_ urls: [URL], tier: SafetyTier) -> [JunkItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return sortedBySize(urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map {
            JunkItem(path: $0.path, name: $0.path.replacingOccurrences(of: home, with: "~"),
                     size: CleanupSizing.allocatedSize(of: $0), tier: tier)
        })
    }

    static func sortedBySize(_ items: [JunkItem]) -> [JunkItem] {
        items.filter { $0.size >= minimumItemSize }.sorted { $0.size > $1.size }
    }

    static func describeAge(days: Double) -> String {
        switch days {
        case ..<1: "today"
        case ..<2: "yesterday"
        case ..<30: "\(Int(days)) days ago"
        case ..<365: "\(Int(days / 30)) month\(days >= 60 ? "s" : "") ago"
        default: "\(Int(days / 365)) year\(days >= 730 ? "s" : "") ago"
        }
    }
}

// MARK: - Device support

/// Xcode keeps debug symbols per device + OS build ("iPhone17,1 27.0 (24A435)"). A device only
/// runs one OS at a time, so older builds for the same device are superseded and safe to remove.
enum DeviceSupport {
    struct Parsed: Equatable {
        let device: String
        let version: [Int]
        let build: String
    }

    /// "iPhone17,1 27.0 (24A5430a)" → device "iPhone17,1", version [27, 0], build "24A5430a".
    /// Older folders are just "17.2 (21C62)" with no device prefix.
    static func parse(_ name: String) -> Parsed? {
        guard let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"), open < close else { return nil }
        let build = String(name[name.index(after: open)..<close])
        let head = name[..<open].trimmingCharacters(in: .whitespaces)
        let parts = head.split(separator: " ")
        guard let versionText = parts.last else { return nil }
        let version = versionText.split(separator: ".").compactMap { Int($0) }
        guard !version.isEmpty else { return nil }
        let device = parts.dropLast().joined(separator: " ")
        return Parsed(device: device.isEmpty ? "device" : device, version: version, build: build)
    }

    /// Newer = higher version; for the same version, a release build (no trailing letter) beats betas,
    /// then the higher build number wins.
    static func isNewer(_ a: Parsed, than b: Parsed) -> Bool {
        if a.version != b.version { return a.version.lexicographicallyPrecedes(b.version) == false }
        let aBeta = a.build.last?.isLetter == true && a.build.dropLast().last?.isNumber == true
        let bBeta = b.build.last?.isLetter == true && b.build.dropLast().last?.isNumber == true
        if aBeta != bBeta { return !aBeta }
        return a.build.compare(b.build, options: .numeric) == .orderedDescending
    }

    static func classify(_ items: [JunkItem]) -> [JunkItem] {
        let parsed = items.map { ($0, parse($0.name)) }
        var newest: [String: Parsed] = [:]
        for case let (_, info?) in parsed {
            if let current = newest[info.device] {
                if isNewer(info, than: current) { newest[info.device] = info }
            } else {
                newest[info.device] = info
            }
        }
        return parsed.map { item, info in
            guard let info, let latest = newest[info.device], latest != info else {
                var kept = item
                kept.detail = "Newest for this device · keep if you still debug on it"
                return kept
            }
            let latestName = "\(latest.version.map(String.init).joined(separator: ".")) (\(latest.build))"
            return JunkItem(path: item.path, name: item.name,
                            detail: "Superseded: this device now uses \(latestName)",
                            size: item.size, tier: .safe)
        }
    }
}

// MARK: - Project dependencies

/// Finds reinstallable dependency/build folders inside projects that have gone quiet.
enum ProjectJunk {
    struct Kind: Sendable {
        let folder: String
        /// A file next to the folder that confirms what it is (package.json next to node_modules).
        let marker: String
        let label: String
        let reinstall: String
    }

    static let kinds: [Kind] = [
        Kind(folder: "node_modules", marker: "package.json", label: "node_modules", reinstall: "npm install"),
        Kind(folder: ".venv", marker: "", label: "Python virtual environment", reinstall: "python -m venv .venv"),
        Kind(folder: "venv", marker: "", label: "Python virtual environment", reinstall: "python -m venv venv"),
        Kind(folder: "target", marker: "Cargo.toml", label: "Rust build output", reinstall: "cargo build"),
        Kind(folder: ".next", marker: "package.json", label: "Next.js build cache", reinstall: "rebuilt on next run"),
        Kind(folder: ".nuxt", marker: "package.json", label: "Nuxt build cache", reinstall: "rebuilt on next run"),
        Kind(folder: ".turbo", marker: "package.json", label: "Turborepo cache", reinstall: "rebuilt on next run"),
        Kind(folder: "Pods", marker: "Podfile", label: "CocoaPods", reinstall: "pod install"),
        Kind(folder: ".build", marker: "Package.swift", label: "Swift package build output", reinstall: "swift build"),
    ]

    /// Where people keep code. Deliberately skips Documents/Desktop to avoid privacy prompts.
    static let rootNames = ["Developer", "Projects", "Code", "code", "src", "dev", "Sites", "workspace", "repos", "GitHub", "git"]

    /// Projects touched in the last 30 days are active; leave them alone.
    static let activeDays: Double = 30
    /// Idle this long and dependencies are clearly safe to drop (they reinstall).
    static let safeDays: Double = 90
    static let maxDepth = 5

    static func find(home: URL, now: Date) -> [JunkItem] {
        let fm = FileManager.default
        var results: [JunkItem] = []
        var seenRoots = Set<String>()
        for name in rootNames {
            let root = home.appending(path: name)
            let resolved = root.resolvingSymlinksInPath().path
            guard fm.fileExists(atPath: root.path), !seenRoots.contains(resolved) else { continue }
            seenRoots.insert(resolved)
            walk(root, depth: 0, home: home, now: now, into: &results)
        }
        return JunkScanners.sortedBySize(results)
    }

    private static func walk(_ directory: URL, depth: Int, home: URL, now: Date, into results: inout [JunkItem]) {
        guard depth <= maxDepth,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
        let names = Set(entries.map(\.lastPathComponent))
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let name = entry.lastPathComponent

            if let kind = match(name: name, siblings: names, entry: entry) {
                let lastTouched = projectLastTouched(directory, ignoring: name)
                let idleDays = lastTouched.map { now.timeIntervalSince($0) / 86_400 } ?? .infinity
                guard idleDays >= activeDays else { continue }
                let size = CleanupSizing.allocatedSize(of: entry)
                let project = directory.lastPathComponent
                let idleText = lastTouched == nil ? "idle" : "not touched in \(describeIdle(days: idleDays))"
                results.append(JunkItem(
                    path: entry.path,
                    name: "\(project)/\(name)",
                    detail: "\(kind.label) · \(idleText) · \(reinstallHint(kind, siblings: names))",
                    size: size,
                    tier: idleDays >= safeDays ? .safe : .review
                ))
                continue // never descend into dependency folders
            }
            // Skip hidden folders (.git etc.), app bundles and anything that's itself a known junk name.
            if name.hasPrefix(".") || name.hasSuffix(".app") || name == "node_modules" { continue }
            walk(entry, depth: depth + 1, home: home, now: now, into: &results)
        }
    }

    static func match(name: String, siblings: Set<String>, entry: URL) -> Kind? {
        for kind in kinds where kind.folder == name {
            if kind.marker.isEmpty {
                // Virtual environments identify themselves with pyvenv.cfg.
                if FileManager.default.fileExists(atPath: entry.appending(path: "pyvenv.cfg").path) { return kind }
            } else if siblings.contains(kind.marker) {
                return kind
            }
        }
        return nil
    }

    /// Most recent change to the project itself: its top-level files plus git activity,
    /// ignoring the dependency folder (installs touch it without you working on the project).
    static func projectLastTouched(_ project: URL, ignoring junkName: String) -> Date? {
        let fm = FileManager.default
        let ignored: Set<String> = Set(kinds.map(\.folder)).union([".DS_Store"])
        var dates: [Date] = []
        if let entries = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for entry in entries where !ignored.contains(entry.lastPathComponent) && entry.lastPathComponent != ".git" {
                if let date = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    dates.append(date)
                }
            }
        }
        for gitFile in [".git/index", ".git/HEAD", ".git/FETCH_HEAD"] {
            if let date = try? fm.attributesOfItem(atPath: project.appending(path: gitFile).path)[.modificationDate] as? Date {
                dates.append(date)
            }
        }
        return dates.max()
    }

    static func reinstallHint(_ kind: Kind, siblings: Set<String>) -> String {
        guard kind.folder == "node_modules" else { return kind.reinstall.hasPrefix("rebuilt") ? kind.reinstall : "reinstall with \(kind.reinstall)" }
        let command: String = if siblings.contains("pnpm-lock.yaml") { "pnpm install" }
            else if siblings.contains("yarn.lock") { "yarn" }
            else if siblings.contains("bun.lockb") || siblings.contains("bun.lock") { "bun install" }
            else { "npm install" }
        return "reinstall with \(command)"
    }

    static func describeIdle(days: Double) -> String {
        switch days {
        case ..<60: "\(Int(days)) days"
        case ..<365: "\(Int(days / 30)) months"
        default: "\(Int(days / 365)) year\(days >= 730 ? "s" : "")"
        }
    }
}

// MARK: - Sizing

enum CleanupSizing {
    /// Real on-disk footprint (allocated blocks), matching what Finder reports.
    static func allocatedSize(of url: URL) -> Int64 {
        var ignored = TopItems(limit: 0)
        return StorageScanner.measure(url, collect: false, into: &ignored).size
    }
}
