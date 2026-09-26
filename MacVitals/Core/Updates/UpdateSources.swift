import Foundation

/// An installed app and where its updates come from.
struct UpdatableApp: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Publishes a Sparkle appcast Mac Vitals can read (and install from).
        case sparkle(feed: URL)
        case appStore
        case homebrew(token: String)
        /// Has its own updater we can't see into (Chrome, Microsoft, Electron apps…).
        case selfUpdating(String)
        /// Apple's own apps outside the App Store: updated with macOS.
        case macOS
        case unknown

        var label: String {
            switch self {
            case .sparkle: "Developer"
            case .appStore: "App Store"
            case .homebrew: "Homebrew"
            case .selfUpdating(let by): by
            case .macOS: "macOS"
            case .unknown: "Unknown"
            }
        }
    }

    let path: String
    let name: String
    let bundleID: String?
    /// CFBundleShortVersionString (what people see).
    let version: String
    /// CFBundleVersion (the build number Sparkle compares).
    let build: String?
    let teamID: String?
    var source: Source

    var id: String { path }
}

/// What a check found for one app.
struct UpdateCheck: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case upToDate
        case available
        /// A newer version exists but needs a newer macOS.
        case needsNewerMacOS(String)
        case failed(String)
        case notCheckable
    }

    var status: Status
    var latestVersion: String?
    var latestBuild: String?
    var downloadURL: URL?
    var size: Int64?
    var releaseNotesURL: URL?
    var notes: String?
    var isCritical = false
    var releaseDate: Date?
    /// App Store product page.
    var storeURL: URL?
}

enum UpdateSources {
    // MARK: Inventory

    static func inventory(bundles: [URL] = AppInventory.appBundles(), brewCasks: [String: BrewCask] = [:]) -> [UpdatableApp] {
        bundles.compactMap { url -> UpdatableApp? in
            guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "?"
            let signature = CodeSignature.check(path: url.path)
            let app = UpdatableApp(path: url.path, name: name, bundleID: bundle.bundleIdentifier, version: version,
                                   build: info["CFBundleVersion"] as? String, teamID: signature.teamID, source: .unknown)
            var result = app
            result.source = source(for: url, info: info, bundleID: bundle.bundleIdentifier,
                                   isApple: signature.trust == .apple, brewToken: brewCasks[url.lastPathComponent]?.token)
            return result
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func source(for url: URL, info: [String: Any], bundleID: String?, isApple: Bool, brewToken: String?) -> UpdatableApp.Source {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appending(path: "Contents/_MASReceipt/receipt").path) { return .appStore }
        // iPhone/iPad apps running on the Mac come from the App Store too.
        if fm.fileExists(atPath: url.appending(path: "Wrapper/iTunesMetadata.plist").path)
            || fm.fileExists(atPath: url.appending(path: "WrappedBundle").path) { return .appStore }
        if let feed = sparkleFeed(info: info, bundleID: bundleID) { return .sparkle(feed: feed) }
        if let brewToken { return .homebrew(token: brewToken) }
        if info["KSProductID"] != nil { return .selfUpdating("Google") }
        let frameworks = url.appending(path: "Contents/Frameworks")
        if fm.fileExists(atPath: frameworks.appending(path: "Squirrel.framework").path) { return .selfUpdating("Built-in updater") }
        if fm.fileExists(atPath: frameworks.appending(path: "Sparkle.framework").path) { return .selfUpdating("Built-in updater") }
        if let bundleID {
            if bundleID.hasPrefix("com.microsoft.") { return .selfUpdating("Microsoft AutoUpdate") }
            if bundleID.hasPrefix("com.adobe.") { return .selfUpdating("Adobe Creative Cloud") }
            if bundleID.hasPrefix("com.setapp.") || info["SetappBundle"] != nil { return .selfUpdating("Setapp") }
            if bundleID.hasPrefix("com.jetbrains.") { return .selfUpdating("JetBrains Toolbox") }
        }
        // Safari updates with macOS; Apple's other downloads (SF Symbols…) don't.
        if isApple && bundleID == "com.apple.Safari" { return .macOS }
        return .unknown
    }

    /// Info.plist first; some apps set the feed in code and save it in their preferences.
    static func sparkleFeed(info: [String: Any], bundleID: String?) -> URL? {
        if let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https" { return feed }
        if let bundleID, let stored = CFPreferencesCopyAppValue("SUFeedURL" as CFString, bundleID as CFString) as? String,
           let feed = URL(string: stored), feed.scheme == "https" {
            return feed
        }
        return nil
    }

    // MARK: Sparkle

    static func checkSparkle(_ app: UpdatableApp, feed: URL, session: URLSession = .shared) async -> UpdateCheck {
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("Mac Vitals (update check)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            return UpdateCheck(status: .failed("Couldn't reach the developer's update feed"))
        }
        return evaluate(app, items: AppcastParser.parse(data))
    }

    static func evaluate(_ app: UpdatableApp, items: [AppcastItem], osVersion: String = Appcast.currentOSVersion) -> UpdateCheck {
        guard !items.isEmpty else { return UpdateCheck(status: .failed("The update feed was empty or unreadable")) }
        let (best, needsNewer) = Appcast.best(items, osVersion: osVersion)
        func newer(_ item: AppcastItem) -> Bool {
            // Compare builds when both sides have them (what Sparkle does), else visible versions.
            if let build = item.version, let installed = app.build { return VersionComparator.isNewer(build, than: installed) }
            return VersionComparator.isNewer(item.displayVersion ?? "0", than: app.version)
        }
        if let best, newer(best) {
            return UpdateCheck(status: .available, latestVersion: best.displayVersion, latestBuild: best.version,
                               downloadURL: best.downloadURL, size: best.length, releaseNotesURL: best.releaseNotesURL,
                               notes: best.notesHTML.map { Appcast.plainText(fromHTML: $0) }.flatMap { $0.isEmpty ? nil : $0 },
                               isCritical: best.isCritical, releaseDate: best.pubDate)
        }
        if let needsNewer {
            let newest = items.filter { $0.channel == nil }.max { VersionComparator.compare($0.version ?? "0", $1.version ?? "0") < 0 }
            if let newest, newer(newest) {
                return UpdateCheck(status: .needsNewerMacOS(needsNewer), latestVersion: newest.displayVersion)
            }
        }
        return UpdateCheck(status: .upToDate, latestVersion: best?.displayVersion)
    }

    // MARK: App Store

    /// Apple's public lookup API, one request for all App Store apps.
    static func checkAppStore(_ apps: [UpdatableApp], session: URLSession = .shared) async -> [String: UpdateCheck] {
        let ids = apps.compactMap(\.bundleID)
        guard !ids.isEmpty else { return [:] }
        let country = Locale.current.region?.identifier.lowercased() ?? "us"
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: ids.joined(separator: ",")),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = components.url, let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return Dictionary(uniqueKeysWithValues: apps.map { ($0.path, UpdateCheck(status: .failed("Couldn't reach the App Store"))) })
        }
        return evaluateAppStore(apps, results: results)
    }

    static func evaluateAppStore(_ apps: [UpdatableApp], results: [[String: Any]]) -> [String: UpdateCheck] {
        var byBundle: [String: [String: Any]] = [:]
        for result in results { if let id = result["bundleId"] as? String { byBundle[id] = result } }
        var checks: [String: UpdateCheck] = [:]
        for app in apps {
            guard let id = app.bundleID, let result = byBundle[id], let latest = result["version"] as? String else {
                checks[app.path] = UpdateCheck(status: .notCheckable)
                continue
            }
            let store = (result["trackViewUrl"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "https://", with: "macappstore://")) }
            let notes = (result["releaseNotes"] as? String).map { Appcast.plainText(fromHTML: $0.replacingOccurrences(of: "\n", with: "<br>")) }
            let released = (result["currentVersionReleaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let newer = VersionComparator.isNewer(latest, than: app.version)
            checks[app.path] = UpdateCheck(status: newer ? .available : .upToDate, latestVersion: newer ? latest : app.version,
                                           size: (result["fileSizeBytes"] as? String).flatMap(Int64.init),
                                           notes: newer ? notes : nil, releaseDate: released, storeURL: store)
        }
        return checks
    }

    // MARK: Homebrew

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func brewEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env.removeValue(forKey: "OS_ACTIVITY_DT_MODE")
        return env
    }

    static func runBrew(_ arguments: [String], environment: [String: String]? = nil) -> (status: Int32, output: String) {
        guard let brew = brewPath else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = arguments
        process.environment = environment ?? brewEnvironment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    struct BrewCask: Equatable, Sendable {
        let token: String
        /// Newest version in Homebrew's definitions (as of its last `brew update`).
        let latest: String
        /// What Homebrew installed.
        let installed: String
        /// The app updates itself; Homebrew's record may be behind the real app.
        let autoUpdates: Bool

        var displayLatest: String { String(latest.split(separator: ",").first ?? Substring(latest)) }
    }

    /// App bundle name → cask, for apps Homebrew installed.
    static func brewCasks() -> [String: BrewCask] {
        let (status, output) = runBrew(["info", "--cask", "--installed", "--json=v2"])
        guard status == 0, let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return parseBrewCasks(json)
    }

    static func parseBrewCasks(_ json: [String: Any]) -> [String: BrewCask] {
        var map: [String: BrewCask] = [:]
        for cask in json["casks"] as? [[String: Any]] ?? [] {
            guard let token = cask["token"] as? String, let latest = cask["version"] as? String,
                  let installed = cask["installed"] as? String else { continue }
            let info = BrewCask(token: token, latest: latest, installed: installed, autoUpdates: cask["auto_updates"] as? Bool ?? false)
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                for app in artifact["app"] as? [Any] ?? [] {
                    if let name = app as? String { map[(name as NSString).lastPathComponent] = info }
                }
            }
        }
        return map
    }

    /// Newer in Homebrew than what's installed. For apps that update themselves, only trust
    /// Homebrew's record if it still matches the app on disk (else the app may be ahead of it).
    static func evaluateBrew(_ app: UpdatableApp, cask: BrewCask) -> UpdateCheck {
        // Homebrew records versions like "2026.1.2.10,quail2,AI-261.25134"; match whole parts,
        // preferring the exact build (a short "2026.1" would match too loosely).
        let parts = Set(cask.installed.split(separator: ",").map(String.init))
        let recordMatchesApp = app.build.map { parts.contains($0) } ?? parts.contains(app.version)
        if cask.latest == cask.installed { return UpdateCheck(status: .upToDate, latestVersion: cask.displayLatest) }
        if cask.autoUpdates && !recordMatchesApp { return UpdateCheck(status: .notCheckable) }
        return UpdateCheck(status: .available, latestVersion: cask.displayLatest)
    }
}
