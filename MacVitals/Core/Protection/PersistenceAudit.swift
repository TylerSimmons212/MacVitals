import Foundation

/// Mac adware and malware almost always make themselves start automatically. This looks at
/// every startup item for the patterns that real Mac threats use: no verified developer,
/// running from a hidden or temporary folder, or a script that downloads and runs code.
///
/// It flags things to look at; it doesn't claim anything is malware.
enum PersistenceAudit {
    enum Level: Int, Comparable, Sendable {
        case fine, review, suspicious
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    enum Concern: Equatable, Sendable {
        case unsigned
        case adHoc
        case invalidSignature
        case temporaryFolder
        case hiddenFolder
        case runsScript(interpreter: String)
        case downloadsAndRuns

        var text: String {
            switch self {
            case .unsigned: "Not signed by any developer"
            case .adHoc: "Not from a developer Apple has verified"
            case .invalidSignature: "Changed after its developer signed it"
            case .temporaryFolder: "Runs from a temporary or shared folder"
            case .hiddenFolder: "Runs from a hidden folder"
            case .runsScript(let interpreter): "Runs a \(interpreter) script"
            case .downloadsAndRuns: "Downloads code from the internet and runs it"
            }
        }
    }

    struct Review: Identifiable, Sendable {
        let item: StartupItem
        /// The code that actually runs (the script, for interpreter-launched items).
        let target: String?
        let signature: CodeSignature?
        let concerns: [Concern]
        let level: Level
        /// "Installed with Homebrew", "Signed by Google LLC"…
        let source: String

        var id: String { item.id }
    }

    struct Launch: Equatable, Sendable {
        let program: String?
        let arguments: [String]
    }

    static let interpreters: [String: String] = [
        "sh": "shell", "bash": "shell", "zsh": "shell", "dash": "shell", "ksh": "shell", "csh": "shell", "tcsh": "shell",
        "python": "Python", "python3": "Python", "perl": "Perl", "ruby": "Ruby", "node": "Node.js", "osascript": "AppleScript",
    ]

    /// Where package managers put things. Their tools are usually ad-hoc signed, and that's fine.
    static func packageManager(for path: String, home: String) -> String? {
        let rules: [(String, String)] = [
            ("/opt/homebrew/", "Homebrew"), ("/usr/local/Cellar/", "Homebrew"), ("/usr/local/opt/", "Homebrew"),
            ("/usr/local/Homebrew/", "Homebrew"), ("/opt/local/", "MacPorts"), ("/nix/", "Nix"),
            (home + "/.nvm/", "nvm"), (home + "/.cargo/", "Cargo"), (home + "/.local/bin/", "pipx"),
            (home + "/.bun/", "Bun"), (home + "/.deno/", "Deno"), (home + "/.volta/", "Volta"),
        ]
        return rules.first { path.hasPrefix($0.0) }?.1
    }

    static func review(_ item: StartupItem, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                       launch: Launch? = nil, signatureCheck: (String) -> CodeSignature = CodeSignature.check(path:)) -> Review {
        let launch = launch ?? readLaunch(item)
        var concerns: [Concern] = []
        var target = launch.program ?? item.appPath ?? item.executablePath
        var signature: CodeSignature?

        // Interpreter + script: judge the script (and any inline command), not /bin/bash.
        if let program = launch.program, let kind = interpreterKind(program, arguments: launch.arguments) {
            concerns.append(.runsScript(interpreter: kind))
            let args = launch.program.map { ($0 as NSString).lastPathComponent == "env" ? Array(launch.arguments.dropFirst()) : launch.arguments } ?? []
            if let inline = inlineCommand(args), downloadsAndRuns(inline) { concerns.append(.downloadsAndRuns) }
            target = scriptPath(in: args) ?? target
        } else if let path = target {
            // Judge the whole app for helpers inside an app bundle.
            let codePath = ProcessGrouping.outermostAppBundle(in: path) ?? path
            target = codePath
            let checked = signatureCheck(codePath)
            signature = checked
            switch checked.trust {
            case .unsigned: concerns.append(.unsigned)
            case .adHoc: concerns.append(.adHoc)
            case .invalid: concerns.append(.invalidSignature)
            case .apple, .verifiedDeveloper, .unknown: break
            }
        }

        let manager = target.flatMap { packageManager(for: $0, home: home) }
        if manager != nil { concerns.removeAll { $0 == .adHoc || $0 == .unsigned } }
        if let path = target {
            if isTemporary(path) { concerns.append(.temporaryFolder) }
            if manager == nil, isInHiddenFolder(path, home: home) { concerns.append(.hiddenFolder) }
        }

        let verified = signature?.isVerified ?? false
        let level: Level
        if concerns.contains(.downloadsAndRuns) || concerns.contains(.temporaryFolder) || concerns.contains(.invalidSignature)
            || (concerns.contains(.hiddenFolder) && !verified) {
            level = .suspicious
        } else if concerns.contains(where: { $0 == .unsigned || $0 == .adHoc }) || (concerns.contains { if case .runsScript = $0 { true } else { false } } && manager == nil) {
            level = .review
        } else {
            level = .fine
        }

        let source: String = if let manager { "Installed with \(manager)" }
            else if signature?.trust == .apple { "Part of macOS" }
            else if let signer = signature?.signer, verified { "Signed by \(signer)" }
            else if let developer = item.developer { developer }
            else { "Unknown developer" }

        return Review(item: item, target: target, signature: signature, concerns: concerns, level: level, source: source)
    }

    static func interpreterKind(_ program: String, arguments: [String]) -> String? {
        let name = (program as NSString).lastPathComponent
        if name == "env", let first = arguments.first { return interpreters[(first as NSString).lastPathComponent] }
        return interpreters[name]
    }

    /// `bash -c "…"` / `python3 -c "…"` / `osascript -e "…"`.
    static func inlineCommand(_ arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(where: { $0 == "-c" || $0 == "-e" || $0 == "-lc" }), flag + 1 < arguments.count else { return nil }
        return arguments[(flag + 1)...].joined(separator: " ")
    }

    /// The classic adware one-liner: fetch a payload and pipe it into a shell, or decode a blob and run it.
    static func downloadsAndRuns(_ command: String) -> Bool {
        let lower = command.lowercased()
        let fetches = lower.contains("curl ") || lower.contains("wget ") || lower.contains("urllib") || lower.contains("nscurl")
        let runs = lower.contains("| sh") || lower.contains("|sh") || lower.contains("| bash") || lower.contains("|bash")
            || lower.contains("| zsh") || lower.contains("| python") || lower.contains("exec(") || lower.contains("eval")
        let decodes = lower.contains("base64 -d") || lower.contains("base64 --decode") || lower.contains("base64 -D")
        return (fetches && runs) || (decodes && runs)
    }

    static func scriptPath(in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix("/") && !$0.hasPrefix("-") }
    }

    static func isTemporary(_ path: String) -> Bool {
        ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/Users/Shared/", "/var/tmp/", "/private/var/tmp/"]
            .contains { path.hasPrefix($0) }
    }

    static func isInHiddenFolder(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let relative = path.dropFirst(home.count + 1)
        // Only folders count (a hidden file name itself is unusual but not the pattern).
        return relative.split(separator: "/").dropLast().contains { $0.hasPrefix(".") }
    }

    static func readLaunch(_ item: StartupItem) -> Launch {
        guard let plistPath = item.plistPath, let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return Launch(program: item.executablePath, arguments: [])
        }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        if let program = plist["Program"] as? String {
            return Launch(program: program, arguments: Array(arguments.dropFirst()))
        }
        return Launch(program: arguments.first ?? item.executablePath, arguments: Array(arguments.dropFirst()))
    }
}

/// Apps in /Applications and ~/Applications that aren't signed by a developer Apple verified.
/// Not bad by itself (open-source and self-built apps often aren't), but worth recognizing.
enum AppSignatureAudit {
    struct Review: Identifiable, Sendable {
        let path: String
        let name: String
        let signature: CodeSignature
        var id: String { path }
    }

    static func run(bundles: [URL] = AppInventory.appBundles()) -> (checked: Int, unverified: [Review]) {
        let reviews = bundles.map { url -> Review in
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            return Review(path: url.path, name: name, signature: CodeSignature.check(path: url.path))
        }
        let unverified = reviews.filter { !$0.signature.isVerified && $0.signature.trust != .unknown }
            .sorted { ($0.signature.trust == .invalid ? 0 : 1, $0.name.lowercased()) < ($1.signature.trust == .invalid ? 0 : 1, $1.name.lowercased()) }
        return (reviews.count, unverified)
    }
}
