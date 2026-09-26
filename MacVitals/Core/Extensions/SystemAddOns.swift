import Foundation

/// Things apps install into macOS itself that tend to outlive the app: audio drivers, network
/// extensions, settings panes, Spotlight and Quick Look plug-ins, old browser plug-ins.
struct SystemAddOn: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case systemExtension, audioDriver, settingsPane, spotlight, quickLook, internetPlugin

        var title: String {
            switch self {
            case .systemExtension: "System extensions"
            case .audioDriver: "Audio drivers"
            case .settingsPane: "Settings panes"
            case .spotlight: "Spotlight plug-ins"
            case .quickLook: "Quick Look plug-ins"
            case .internetPlugin: "Browser plug-ins"
            }
        }

        var explanation: String {
            switch self {
            case .systemExtension: "Network filters, VPNs and drivers that run as part of macOS."
            case .audioDriver: "Virtual sound devices from screen recorders, meeting and streaming apps. They show up in Sound settings."
            case .settingsPane: "Panels an app adds to System Settings."
            case .spotlight: "Teach Spotlight to search inside a kind of file."
            case .quickLook: "Old-style preview plug-ins. macOS no longer loads them."
            case .internetPlugin: "Old browser plug-ins like Flash. No current browser uses them."
            }
        }

        var icon: String {
            switch self {
            case .systemExtension: "puzzlepiece.extension"
            case .audioDriver: "speaker.wave.2"
            case .settingsPane: "gearshape"
            case .spotlight: "magnifyingglass"
            case .quickLook: "eye"
            case .internetPlugin: "globe"
            }
        }
    }

    enum Status: Equatable, Hashable, Sendable {
        case inUse(app: String?)
        /// Its app is gone.
        case leftover
        /// macOS no longer uses this kind at all.
        case obsolete
    }

    let kind: Kind
    let name: String
    let bundleID: String?
    let version: String?
    let path: String?
    let teamID: String?
    let status: Status
    /// Extra detail (system extension state, e.g. "Network extension · enabled").
    var detail: String? = nil

    var id: String { "\(kind.rawValue)|\(bundleID ?? path ?? name)" }

    /// Leftovers and obsolete plug-ins in folders can go to the Trash. System extensions are
    /// managed by macOS (Settings), never by deleting files.
    var isRemovable: Bool { kind != .systemExtension && path != nil && !isInUse }
    var isInUse: Bool { if case .inUse = status { true } else { false } }
}

enum SystemAddOns {
    /// Installed apps' Team IDs and bundle IDs, to find each add-on's owner.
    struct Owners: Sendable {
        var byTeam: [String: String] = [:]
        var bundleIDs: [(id: String, name: String)] = []

        static func current(bundles: [URL] = AppInventory.appBundles()) -> Owners {
            var owners = Owners()
            for url in bundles {
                let name = (url.lastPathComponent as NSString).deletingPathExtension
                if let team = CodeSignature.check(path: url.path).teamID, owners.byTeam[team] == nil { owners.byTeam[team] = name }
                if let id = Bundle(url: url)?.bundleIdentifier { owners.bundleIDs.append((id.lowercased(), name)) }
            }
            return owners
        }

        /// Words too generic to identify a product.
        static let genericWords: Set<String> = ["microsoft", "apple", "google", "adobe", "studio", "visual", "desktop",
                                                 "client", "helper", "audio", "driver", "plugin", "device", "macos", "system"]

        /// The app this belongs to: a bundle ID that starts the same way (com.vendor.product), or
        /// the app's name inside the add-on's ID or name ("teams" → Microsoft Teams). Sharing only
        /// a developer isn't enough: MacPaw makes both CleanMyMac and ClearVPN.
        func owner(bundleID: String?, name: String? = nil) -> String? {
            let id = bundleID?.lowercased() ?? ""
            let parts = id.split(separator: ".")
            if parts.count >= 3 {
                let prefix = parts.prefix(3).joined(separator: ".")
                if let app = bundleIDs.first(where: { $0.id.hasPrefix(prefix) }) { return app.name }
            }
            let haystack = (id + " " + (name ?? "")).lowercased().replacingOccurrences(of: " ", with: "")
            for app in bundleIDs {
                let words = app.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init).filter { $0.count >= 5 && !Self.genericWords.contains($0) }
                if words.contains(where: { haystack.contains($0) }) { return app.name }
            }
            return nil
        }

        /// Same developer, for "made by the developer of X" when the product itself is gone.
        func sameDeveloper(teamID: String?) -> String? { teamID.flatMap { byTeam[$0] } }
    }

    static func all(owners: Owners = .current(), home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [SystemAddOn] {
        var found = systemExtensions(owners: owners)
        let folders: [(SystemAddOn.Kind, String, String)] = [
            (.audioDriver, "/Library/Audio/Plug-Ins/HAL", "driver"), (.audioDriver, home + "/Library/Audio/Plug-Ins/HAL", "driver"),
            (.settingsPane, "/Library/PreferencePanes", "prefPane"), (.settingsPane, home + "/Library/PreferencePanes", "prefPane"),
            (.spotlight, "/Library/Spotlight", "mdimporter"), (.spotlight, home + "/Library/Spotlight", "mdimporter"),
            (.quickLook, "/Library/QuickLook", "qlgenerator"), (.quickLook, home + "/Library/QuickLook", "qlgenerator"),
            (.internetPlugin, "/Library/Internet Plug-Ins", "plugin"), (.internetPlugin, home + "/Library/Internet Plug-Ins", "plugin"),
        ]
        for (kind, folder, ext) in folders {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where (file as NSString).pathExtension == ext {
                found.append(bundled(kind, path: folder + "/" + file, owners: owners))
            }
        }
        return found
    }

    static func bundled(_ kind: SystemAddOn.Kind, path: String, owners: Owners) -> SystemAddOn {
        let info = Bundle(path: path)?.infoDictionary ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String
        let name = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let signature = CodeSignature.check(path: path)
        let status: SystemAddOn.Status
        if kind == .quickLook || kind == .internetPlugin {
            status = .obsolete
        } else if signature.trust == .apple {
            status = .inUse(app: "macOS")
        } else if let app = owners.owner(bundleID: bundleID, name: name) {
            status = .inUse(app: app)
        } else {
            status = .leftover
        }
        return SystemAddOn(kind: kind, name: name, bundleID: bundleID, version: info["CFBundleShortVersionString"] as? String,
                           path: path, teamID: signature.teamID, status: status,
                           detail: status == .leftover ? owners.sameDeveloper(teamID: signature.teamID).map { "same developer as \($0)" } : nil)
    }

    // MARK: System extensions (systemextensionsctl)

    static func systemExtensions(owners: Owners) -> [SystemAddOn] {
        parseSystemExtensions(DefenceChecks.run("/usr/bin/systemextensionsctl", ["list"])).map { entry in
            let app = owners.owner(bundleID: entry.bundleID, name: entry.name)
            let developer = app == nil ? owners.sameDeveloper(teamID: entry.teamID).map { " · same developer as \($0)" } ?? "" : ""
            return SystemAddOn(kind: .systemExtension, name: entry.name, bundleID: entry.bundleID, version: entry.version,
                               path: nil, teamID: entry.teamID, status: app.map { .inUse(app: $0) } ?? .leftover,
                               detail: "\(entry.category) · \(entry.enabled ? "on" : "off")" + developer)
        }
    }

    struct ExtensionEntry: Equatable {
        let category: String
        let teamID: String
        let bundleID: String
        let version: String?
        let name: String
        let enabled: Bool
        let state: String
    }

    /// Rows look like: "*\t*\tTEAMID\tcom.x.ext (1.2/3)\tName\t[activated enabled]", grouped
    /// under "--- com.apple.system_extension.network_extension" headers.
    static func parseSystemExtensions(_ output: String) -> [ExtensionEntry] {
        var category = "System extension"
        var entries: [ExtensionEntry] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("---") {
                if line.contains("network_extension") { category = "Network extension" }
                else if line.contains("driver_extension") { category = "Driver" }
                else if line.contains("endpoint_security") { category = "Security monitor" }
                else { category = "System extension" }
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 6, columns[2].count == 10 || columns[2] == "-" else { continue }
            let bundleAndVersion = columns[3]
            let bundleID = String(bundleAndVersion.split(separator: " ").first ?? "")
            let version = bundleAndVersion.firstMatch(of: /\(([^\/)]+)/).map { String($0.1) }
            let state = columns[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            // Old versions waiting to be removed show as "terminated waiting to uninstall".
            guard !state.contains("uninstall") else { continue }
            entries.append(ExtensionEntry(category: category, teamID: columns[2], bundleID: bundleID, version: version,
                                          name: columns[4], enabled: columns[0] == "*", state: state))
        }
        return entries
    }
}
