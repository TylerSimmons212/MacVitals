import Foundation

/// A browser extension, in plain terms: which browser, where it came from, what it can do.
struct BrowserExtension: Identifiable, Hashable, Sendable {
    enum Browser: String, CaseIterable, Sendable {
        case chrome, arc, brave, edge, vivaldi, opera, chromium, firefox, safari

        var name: String {
            switch self {
            case .chrome: "Chrome"
            case .arc: "Arc"
            case .brave: "Brave"
            case .edge: "Edge"
            case .vivaldi: "Vivaldi"
            case .opera: "Opera"
            case .chromium: "Chromium"
            case .firefox: "Firefox"
            case .safari: "Safari"
            }
        }

        var bundleID: String {
            switch self {
            case .chrome: "com.google.Chrome"
            case .arc: "company.thebrowser.Browser"
            case .brave: "com.brave.Browser"
            case .edge: "com.microsoft.edgemac"
            case .vivaldi: "com.vivaldi.Vivaldi"
            case .opera: "com.operasoftware.Opera"
            case .chromium: "org.chromium.Chromium"
            case .firefox: "org.mozilla.firefox"
            case .safari: "com.apple.Safari"
            }
        }

        /// Chromium-family data folder under ~/Library/Application Support.
        var chromiumFolder: String? {
            switch self {
            case .chrome: "Google/Chrome"
            case .arc: "Arc/User Data"
            case .brave: "BraveSoftware/Brave-Browser"
            case .edge: "Microsoft Edge"
            case .vivaldi: "Vivaldi"
            case .opera: "com.operasoftware.Opera"
            case .chromium: "Chromium"
            case .firefox, .safari: nil
            }
        }
    }

    enum Source: Equatable, Hashable, Sendable {
        case store
        /// Installed by another program, not from the browser's store.
        case outsideStore
        /// Loaded from a folder with developer mode (you or a developer tool).
        case developer
        /// Forced on by a policy or configuration profile: can't be removed in the browser.
        case policy
        /// Comes inside an app (Safari).
        case app(String)

        var label: String {
            switch self {
            case .store: "From the store"
            case .outsideStore: "Installed from outside the store"
            case .developer: "Loaded from a folder (developer mode)"
            case .policy: "Forced on by a policy"
            case .app(let name): "Comes with \(name)"
            }
        }
    }

    enum Concern: String, Hashable, Sendable {
        case policy, outsideStore, unsigned, broadAccess, disabled

        var text: String {
            switch self {
            case .policy: "Forced on by a policy or profile, so it can't be removed in the browser. A common adware trick, unless your work or school manages this Mac."
            case .outsideStore: "Not installed from the browser's store. Usually added by another app's installer."
            case .unsigned: "Not signed by Mozilla."
            case .broadAccess: "Can read and change every website you visit. Normal for ad blockers and password managers; worth knowing for anything else."
            case .disabled: "Switched off. Remove it if you don't use it."
            }
        }
    }

    enum Level: Int, Comparable, Sendable {
        case fine, info, review, suspicious
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    let browser: Browser
    let profile: String?
    let extensionID: String
    let name: String
    let version: String?
    let summary: String?
    let enabled: Bool?
    let source: Source
    /// What it's allowed to do, in plain words.
    let access: [String]
    let hasBroadAccess: Bool
    /// Files on disk (for Reveal).
    let path: String?

    var id: String { "\(browser.rawValue)|\(profile ?? "")|\(extensionID)" }

    var concerns: [Concern] {
        var list: [Concern] = []
        if source == .policy { list.append(.policy) }
        if source == .outsideStore { list.append(.outsideStore) }
        if browser == .firefox && summary == "unsigned" { list.append(.unsigned) }
        if hasBroadAccess { list.append(.broadAccess) }
        if enabled == false { list.append(.disabled) }
        return list
    }

    var level: Level {
        if source == .policy || (source == .outsideStore && hasBroadAccess) { return .suspicious }
        if source == .outsideStore || concerns.contains(.unsigned) { return .review }
        if hasBroadAccess || enabled == false { return .info }
        return .fine
    }

    /// Chrome Web Store page (it has the Remove button), for store extensions.
    var storeURL: URL? {
        guard source == .store else { return nil }
        switch browser {
        case .chrome, .arc, .brave, .vivaldi, .chromium, .opera:
            return URL(string: "https://chromewebstore.google.com/detail/\(extensionID)")
        case .edge:
            return URL(string: "https://microsoftedge.microsoft.com/addons/detail/\(extensionID)")
        case .firefox:
            return URL(string: "https://addons.mozilla.org/firefox/addon/\(extensionID)")
        case .safari:
            return nil
        }
    }
}

/// Reads extensions from each browser's own files (small JSON files; nothing heavy), never
/// changing them. Removing happens in the browser, which is the only safe place.
enum BrowserExtensions {
    static func all(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [BrowserExtension] {
        var found: [BrowserExtension] = []
        for browser in BrowserExtension.Browser.allCases {
            if let folder = browser.chromiumFolder {
                found += chromium(browser, root: home + "/Library/Application Support/" + folder)
            }
        }
        found += firefox(root: home + "/Library/Application Support/Firefox/Profiles")
        found += safari()
        return found.sorted { ($0.level, $1.name.lowercased()) > ($1.level, $0.name.lowercased()) }
    }

    // MARK: Chromium family (Chrome, Arc, Brave, Edge…)

    /// Chrome's install locations (`extensions.settings.*.location`).
    static func source(location: Int?, fromStore: Bool?, forcedIDs: Set<String>, id: String) -> BrowserExtension.Source {
        if forcedIDs.contains(id) { return .policy }
        switch location {
        case 4, 8: return .developer         // unpacked, command line
        case 7, 9: return .policy            // policy download / external policy
        case 2, 3, 6: return .outsideStore   // external pref / registry / pref download
        default: return fromStore == false && location == 1 ? .outsideStore : .store
        }
    }

    static func chromium(_ browser: BrowserExtension.Browser, root: String) -> [BrowserExtension] {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let names = profileNames(root: root)
        let forced = forcedExtensionIDs(browser)
        var found: [BrowserExtension] = []
        for profile in profiles where profile == "Default" || profile.hasPrefix("Profile ") {
            let profileRoot = root + "/" + profile
            let settings = extensionSettings(profileRoot)
            var seen: Set<String> = []
            // Installed packages: Extensions/<id>/<version>/manifest.json
            for id in (try? fm.contentsOfDirectory(atPath: profileRoot + "/Extensions")) ?? [] where id.count == 32 {
                let versions = ((try? fm.contentsOfDirectory(atPath: profileRoot + "/Extensions/" + id)) ?? []).sorted()
                guard let version = versions.last else { continue }
                let folder = profileRoot + "/Extensions/\(id)/\(version)"
                guard let manifest = readJSON(folder + "/manifest.json") else { continue }
                let setting = settings[id] ?? [:]
                if (setting["was_installed_by_default"] as? Bool) == true { continue }
                seen.insert(id)
                if let item = make(browser, profile: names[profile] ?? profile, id: id, manifest: manifest, folder: folder,
                                   setting: setting, forced: forced) { found.append(item) }
            }
            // Unpacked (developer mode) extensions live wherever they were loaded from.
            for (id, value) in settings where !seen.contains(id) {
                guard let setting = value as? [String: Any], (setting["location"] as? Int) == 4,
                      let path = setting["path"] as? String, let manifest = readJSON(path + "/manifest.json") else { continue }
                if let item = make(browser, profile: names[profile] ?? profile, id: id, manifest: manifest, folder: path,
                                   setting: setting, forced: forced) { found.append(item) }
            }
        }
        return found
    }

    private static func make(_ browser: BrowserExtension.Browser, profile: String, id: String, manifest: [String: Any],
                             folder: String, setting: [String: Any], forced: Set<String>) -> BrowserExtension? {
        // Themes and built-in apps aren't extensions people think about.
        if manifest["theme"] != nil { return nil }
        let name = localized(manifest["name"] as? String, folder: folder, defaultLocale: manifest["default_locale"] as? String) ?? id
        let description = localized(manifest["description"] as? String, folder: folder, defaultLocale: manifest["default_locale"] as? String)
        let disableReasons = setting["disable_reasons"] as? [Any]
        let state = setting["state"] as? Int
        let enabled: Bool? = if let disableReasons { disableReasons.isEmpty } else if let state { state == 1 } else { nil }
        let (access, broad) = accessSummary(manifest)
        return BrowserExtension(browser: browser, profile: profile, extensionID: id, name: name,
                                version: manifest["version"] as? String, summary: description, enabled: enabled,
                                source: source(location: setting["location"] as? Int, fromStore: setting["from_webstore"] as? Bool,
                                               forcedIDs: forced, id: id),
                                access: access, hasBroadAccess: broad, path: folder)
    }

    /// "Secure Preferences" (newer Chrome) or "Preferences" → extensions.settings.
    static func extensionSettings(_ profileRoot: String) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for file in ["Preferences", "Secure Preferences"] {
            let settings = (readJSON(profileRoot + "/" + file)?["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
            for (id, value) in settings {
                if let dict = value as? [String: Any] { result[id, default: [:]].merge(dict) { $1 } }
            }
        }
        return result
    }

    /// Profile display names from "Local State".
    static func profileNames(root: String) -> [String: String] {
        let cache = ((readJSON(root + "/Local State")?["profile"] as? [String: Any])?["info_cache"] as? [String: Any]) ?? [:]
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }

    /// Extensions forced on by policy (ExtensionInstallForcelist), user or managed.
    static func forcedExtensionIDs(_ browser: BrowserExtension.Browser) -> Set<String> {
        let paths = [
            "/Library/Managed Preferences/\(NSUserName())/\(browser.bundleID).plist",
            "/Library/Managed Preferences/\(browser.bundleID).plist",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Preferences/\(browser.bundleID).plist",
        ]
        var ids: Set<String> = []
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let list = plist["ExtensionInstallForcelist"] as? [String] else { continue }
            for entry in list { ids.insert(String(entry.split(separator: ";").first ?? "")) }
        }
        return ids
    }

    /// Resolves "__MSG_appName__" from _locales.
    static func localized(_ value: String?, folder: String, defaultLocale: String?) -> String? {
        guard let value else { return nil }
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
        let key = String(value.dropFirst(6).dropLast(2)).lowercased()
        for locale in [Locale.current.language.languageCode?.identifier, defaultLocale, "en", "en_US"].compactMap({ $0 }) {
            guard let messages = readJSON(folder + "/_locales/\(locale)/messages.json") else { continue }
            for (messageKey, entry) in messages where messageKey.lowercased() == key {
                if let message = (entry as? [String: Any])?["message"] as? String { return message }
            }
        }
        return nil
    }

    /// Permissions, in plain words, plus whether it can touch every website.
    static func accessSummary(_ manifest: [String: Any]) -> ([String], Bool) {
        var permissions = Set((manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String })
        permissions.formUnion((manifest["host_permissions"] as? [Any] ?? []).compactMap { $0 as? String })
        let scriptMatches = (manifest["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [String] ?? [] }
        let broadPatterns: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*", "*://*/"]
        let broad = !permissions.isDisjoint(with: broadPatterns) || scriptMatches.contains { broadPatterns.contains($0) }
        let plain: [(String, String)] = [
            ("history", "See your browsing history"), ("cookies", "Read cookies (how sites keep you signed in)"),
            ("webRequest", "Watch the pages you load"), ("webRequestBlocking", "Block or change what pages load"),
            ("declarativeNetRequest", "Block or redirect requests (ad blocking)"), ("proxy", "Route your traffic through a proxy"),
            ("management", "Manage your other extensions"), ("nativeMessaging", "Talk to an app on your Mac"),
            ("downloads", "See and manage your downloads"), ("clipboardRead", "Read your clipboard"),
            ("debugger", "Take full control of pages"), ("privacy", "Change privacy settings"),
            ("tabs", "See your open tabs"), ("geolocation", "Use your location"),
        ]
        var access: [String] = broad ? ["Read and change everything on every website"] : []
        access += plain.filter { permissions.contains($0.0) }.map(\.1)
        return (access, broad)
    }

    // MARK: Firefox

    static func firefox(root: String) -> [BrowserExtension] {
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return profiles.flatMap { profile -> [BrowserExtension] in
            guard let json = readJSON(root + "/\(profile)/extensions.json") else { return [] }
            return parseFirefox(json, profile: profile.split(separator: ".").last.map(String.init) ?? profile)
        }
    }

    static func parseFirefox(_ json: [String: Any], profile: String) -> [BrowserExtension] {
        (json["addons"] as? [[String: Any]] ?? []).compactMap { addon in
            guard (addon["type"] as? String) == "extension",
                  let location = addon["location"] as? String, location == "app-profile" || location == "app-global",
                  let id = addon["id"] as? String else { return nil }
            let name = (addon["defaultLocale"] as? [String: Any])?["name"] as? String ?? id
            let signed = (addon["signedState"] as? Int).map { $0 > 0 } ?? true
            let permissions = ((addon["userPermissions"] as? [String: Any])?["origins"] as? [String] ?? [])
                + ((addon["userPermissions"] as? [String: Any])?["permissions"] as? [String] ?? [])
            let (access, broad) = accessSummary(["permissions": permissions])
            let fromStore = (addon["sourceURI"] as? String)?.contains("addons.mozilla.org") ?? signed
            return BrowserExtension(browser: .firefox, profile: profile, extensionID: id, name: name,
                                    version: addon["version"] as? String, summary: signed ? nil : "unsigned",
                                    enabled: addon["active"] as? Bool,
                                    source: location == "app-global" ? .outsideStore : fromStore ? .store : .outsideStore,
                                    access: access, hasBroadAccess: broad, path: addon["path"] as? String)
        }
    }

    // MARK: Safari

    /// Safari extensions ship inside apps; macOS keeps the list (pluginkit).
    static func safari() -> [BrowserExtension] {
        let points = ["com.apple.Safari.web-extension", "com.apple.Safari.content-blocker", "com.apple.Safari.extension"]
        return points.flatMap { point -> [BrowserExtension] in
            let output = DefenceChecks.run("/usr/bin/pluginkit", ["-mAvvv", "-p", point])
            return parsePluginkit(output).map { entry in
                BrowserExtension(browser: .safari, profile: nil, extensionID: entry.bundleID, name: entry.name,
                                 version: entry.version, summary: point.hasSuffix("content-blocker") ? "Content blocker" : nil,
                                 enabled: nil, source: .app(entry.appName ?? "an app"),
                                 access: point.hasSuffix("content-blocker") ? ["Block content on websites"] : [],
                                 hasBroadAccess: false, path: entry.appPath ?? entry.path)
            }
        }
    }

    struct PluginEntry: Equatable {
        let bundleID: String
        let version: String?
        let name: String
        let path: String?
        let appPath: String?
        var appName: String? { appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } }
    }

    /// `pluginkit -mAvvv` prints a block per plug-in: "  com.x.Ext(1.2.3)" then "Path = …", "Display Name = …".
    static func parsePluginkit(_ output: String) -> [PluginEntry] {
        var entries: [PluginEntry] = []
        var bundleID: String?, version: String?, name: String?, path: String?
        func flush() {
            if let bundleID {
                let appPath = path.flatMap { ProcessGrouping.outermostAppBundle(in: $0) }
                entries.append(PluginEntry(bundleID: bundleID, version: version,
                                           name: name ?? appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? bundleID,
                                           path: path, appPath: appPath))
            }
            bundleID = nil; version = nil; name = nil; path = nil
        }
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = line.firstMatch(of: /^[+\-!=\s]*([A-Za-z0-9._-]+)\(([^)]*)\)$/) {
                flush()
                bundleID = String(match.1)
                version = String(match.2)
            } else if let match = line.firstMatch(of: /^Path = (.+)$/) {
                path = String(match.1)
            } else if let match = line.firstMatch(of: /^Display Name = (.+)$/) {
                name = String(match.1)
            }
        }
        flush()
        return entries
    }

    // MARK: Helpers

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
