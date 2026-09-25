import Foundation
import AppKit
import CoreServices

/// An app you installed, with what it really costs (the bundle plus the data it keeps in
/// your Library) and when you last used it.
struct InstalledApp: Identifiable, Sendable {
    let path: String
    let name: String
    let bundleID: String?
    let version: String?
    let appSize: Int64
    let leftovers: [JunkItem]
    /// From Spotlight (kMDItemLastUsedDate). For apps never opened, Spotlight reports the
    /// install date here, so pair it with `neverOpened`.
    let lastUsed: Date?
    /// Spotlight's "last used" is just the install date: it hasn't been opened since installing.
    var neverOpened = false
    let isAppStore: Bool

    var id: String { path }
    var dataSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { appSize + dataSize }

    /// Not opened in six months (or ever, as far as Spotlight knows).
    func isUnused(now: Date = Date()) -> Bool {
        guard let lastUsed else { return true }
        return now.timeIntervalSince(lastUsed) > AppInventory.unusedAfter
    }

    /// The app bundle itself, as a removable item.
    var bundleItem: JunkItem {
        JunkItem(path: path, name: "\(name).app", detail: "The app itself", size: appSize, tier: .review)
    }
}

enum AppInventory {
    static let unusedAfter: TimeInterval = 180 * 86_400

    // MARK: Installed apps

    static func appFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"), home.appending(path: "Applications")]
    }

    /// App bundles you could uninstall. Skips anything on the protected system volume
    /// (Safari lives there even though it shows in /Applications).
    static func appBundles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        var bundles: [URL] = []
        for folder in appFolders(home: home) {
            guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in contents where url.pathExtension == "app" {
                let resolved = url.resolvingSymlinksInPath().path
                guard !resolved.hasPrefix("/System/") else { continue }
                bundles.append(url)
            }
        }
        return bundles
    }

    static func inspect(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstalledApp {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let bundleID = bundle?.bundleIdentifier
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let names = candidateNames(displayName: name, info: info)
        let usage = usage(url)
        return InstalledApp(
            path: url.path,
            name: name,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            appSize: CleanupSizing.allocatedSize(of: url),
            leftovers: bundleID.map { leftovers(bundleID: $0, names: names, home: home) } ?? [],
            lastUsed: usage.lastUsed,
            neverOpened: usage.neverOpened,
            isAppStore: FileManager.default.fileExists(atPath: url.appending(path: "Contents/_MASReceipt").path)
        )
    }

    /// Spotlight sets "last used" to the creation date for items that were never opened
    /// (verified: a freshly created bundle reports lastUsed == creation date). So if the two
    /// match, the app hasn't been opened since it was installed.
    static func usage(_ url: URL) -> (lastUsed: Date?, neverOpened: Bool) {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return (nil, false) }
        let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let created = MDItemCopyAttribute(item, kMDItemContentCreationDate) as? Date
        return (lastUsed, isNeverOpened(lastUsed: lastUsed, created: created))
    }

    static func isNeverOpened(lastUsed: Date?, created: Date?) -> Bool {
        guard let lastUsed else { return true }
        guard let created else { return false }
        return abs(lastUsed.timeIntervalSince(created)) < 60
    }

    // MARK: Leftovers of an installed app

    /// Names too generic to match a folder on (VS Code's executable is literally "Electron").
    static let genericNames: Set<String> = ["Electron", "Helper", "App", "Application", "Agent", "Updater", "Launcher", "Setup", "Installer"]

    static func candidateNames(displayName: String, info: [String: Any]) -> Set<String> {
        let raw = [displayName, info["CFBundleName"] as? String, info["CFBundleExecutable"] as? String].compactMap { $0 }
        return Set(raw.filter { $0.count >= 3 && !genericNames.contains($0) })
    }

    /// Where apps keep data in your Library. Matched only on exact bundle ID / exact names.
    static func leftovers(bundleID: String, names: Set<String>, home: URL) -> [JunkItem] {
        let library = home.appending(path: "Library")
        let fm = FileManager.default
        var found: [String: JunkItem] = [:]

        func add(_ url: URL, label: String, tier: SafetyTier = .safe) {
            guard fm.fileExists(atPath: url.path), found[url.path] == nil else { return }
            found[url.path] = JunkItem(path: url.path, name: label, detail: url.path.replacingOccurrences(of: home.path, with: "~"),
                                       size: CleanupSizing.allocatedSize(of: url), tier: tier)
        }

        // Match against the real on-disk spelling. macOS folder names ignore case, so a lowercase
        // "claude" would otherwise resolve to Claude's "Claude" folder and steal another app's data.
        let exactFolders: [(String, String)] = [
            ("Application Support", "App data"),
            ("Caches", "Cache"),
            ("Logs", "Logs"),
        ]
        for (folder, label) in exactFolders {
            let dir = library.appending(path: folder)
            let entries = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            for name in names.union([bundleID]) where entries.contains(name) {
                add(dir.appending(path: name), label: label)
            }
        }
        add(library.appending(path: "Containers/\(bundleID)"), label: "Sandbox data")
        add(library.appending(path: "Application Scripts/\(bundleID)"), label: "Scripts")
        add(library.appending(path: "Saved Application State/\(bundleID).savedState"), label: "Saved windows")
        add(library.appending(path: "Preferences/\(bundleID).plist"), label: "Settings")
        add(library.appending(path: "HTTPStorages/\(bundleID)"), label: "Web data")
        add(library.appending(path: "HTTPStorages/\(bundleID).binarycookies"), label: "Cookies")
        add(library.appending(path: "Cookies/\(bundleID).binarycookies"), label: "Cookies")
        add(library.appending(path: "WebKit/\(bundleID)"), label: "Web data")
        for folder in ["Preferences/ByHost", "LaunchAgents"] {
            let dir = library.appending(path: folder)
            for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where entry.hasPrefix(bundleID + ".") {
                add(dir.appending(path: entry), label: folder == "LaunchAgents" ? "Starts at login" : "Settings",
                    tier: folder == "LaunchAgents" ? .review : .safe)
            }
        }
        return found.values.sorted { $0.size > $1.size }
    }

    // MARK: Leftovers of deleted apps

    /// Library folders that apps name after their bundle ID.
    static let orphanLocations: [(folder: String, suffix: String, label: String)] = [
        ("Application Support", "", "App data"),
        ("Caches", "", "Cache"),
        ("Containers", "", "Sandbox data"),
        ("Application Scripts", "", "Scripts"),
        ("Saved Application State", ".savedState", "Saved windows"),
        ("HTTPStorages", "", "Web data"),
        ("WebKit", "", "Web data"),
        ("Logs", "", "Logs"),
        ("Preferences", ".plist", "Settings"),
        ("LaunchAgents", ".plist", "Starts at login"),
    ]

    /// "com.spotify.client"-style names: three or more dot-separated parts.
    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    /// Finds Library data whose app is no longer installed anywhere on this Mac.
    /// `isInstalled` is injected so tests can fake LaunchServices.
    static func orphans(home: URL, installedIDs: Set<String>, isInstalled: (String) -> Bool = defaultIsInstalled) -> [JunkGroup] {
        let library = home.appending(path: "Library")
        let fm = FileManager.default
        let ownID = Bundle.main.bundleIdentifier ?? "com.tylersimmons.MacVitals"
        var byID: [String: [JunkItem]] = [:]
        var installedCache: [String: Bool] = [:]

        func stillInstalled(_ id: String) -> Bool {
            if let cached = installedCache[id] { return cached }
            // Helpers often extend an installed app's ID (com.google.Chrome.helper) or vice versa.
            let related = installedIDs.contains { $0 == id || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
            let result = related || isInstalled(id)
            installedCache[id] = result
            return result
        }

        for location in orphanLocations {
            let dir = library.appending(path: location.folder)
            for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard entry.hasSuffix(location.suffix) else { continue }
                let id = String(entry.dropLast(location.suffix.count))
                let lower = id.lowercased()
                guard looksLikeBundleID(id), !lower.hasPrefix("com.apple."), id != ownID,
                      // Tool caches (SwiftPM etc.) aren't apps and are already under Developer Junk.
                      !(location.folder == "Caches" && JunkScanners.developerCacheNames.contains(id)),
                      !stillInstalled(id) else { continue }
                let url = dir.appending(path: entry)
                let item = JunkItem(path: url.path, name: location.label,
                                    detail: url.path.replacingOccurrences(of: home.path, with: "~"),
                                    size: CleanupSizing.allocatedSize(of: url),
                                    tier: location.folder == "LaunchAgents" ? .careful : .review)
                byID[id, default: []].append(item)
            }
        }

        return byID.compactMap { id, items -> JunkGroup? in
            let total = items.reduce(0) { $0 + $1.size }
            guard total >= 512_000 else { return nil } // skip crumbs
            let sibling = installedSibling(of: id, installedIDs: installedIDs)
            return JunkGroup(
                id: "orphan-\(id)", title: prettyName(for: id), icon: "app.dashed",
                explanation: sibling.map { "Data left behind by \(id). Another app from the same developer (\($0)) is still installed, so this may be data from an older version of it." }
                    ?? "Data left behind by \(id), which isn't installed on this Mac anymore.",
                afterRemoval: "Only matters if you reinstall it later; it would start fresh.",
                items: items.sorted { $0.size > $1.size }.map { item in
                    var labeled = item
                    labeled.detail = [item.detail, id].compactMap { $0 }.joined(separator: " · ")
                    return labeled
                }
            )
        }
        .sorted { $0.totalSize > $1.totalSize }
    }

    /// An installed app from the same developer (same first two parts of the bundle ID).
    static func installedSibling(of id: String, installedIDs: Set<String>) -> String? {
        let vendor = id.split(separator: ".").prefix(2).joined(separator: ".")
        return installedIDs.filter { $0.split(separator: ".").prefix(2).joined(separator: ".") == vendor }.sorted().first
    }

    static func defaultIsInstalled(_ id: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// "com.spotify.client" → "Spotify", "com.hnc.Discord" → "Discord", "org.whispersystems.signal-desktop" → "Signal Desktop".
    static func prettyName(for bundleID: String) -> String {
        let parts = bundleID.split(separator: ".").map(String.init)
        let generic: Set<String> = ["client", "app", "mac", "macos", "osx", "desktop", "application", "main"]
        let product = parts.count >= 3 ? parts[2] : parts.last ?? bundleID
        let chosen = generic.contains(product.lowercased()) && parts.count >= 2 ? parts[1] : product
        return chosen
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Bundle IDs of every app we can see, used to decide what's "deleted".
    static func installedBundleIDs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        var ids = Set(appBundles(home: home).compactMap { Bundle(url: $0)?.bundleIdentifier })
        for app in NSWorkspace.shared.runningApplications { if let id = app.bundleIdentifier { ids.insert(id) } }
        return ids
    }
}
