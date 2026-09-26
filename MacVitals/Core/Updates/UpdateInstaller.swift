import Foundation
import AppKit
import Security

/// Installs an update from an app's own Sparkle feed, with the same safety rules Sparkle uses:
/// the new app must be signed by the *same developer* (Team ID) as the one installed, the
/// signature must check out in full, and it must actually be newer. The old version goes to
/// the Trash, not deleted, and the app is reopened if it was running.
enum UpdateInstaller {
    enum Step: Equatable, Sendable {
        case downloading(Double)
        case verifying
        case installing
    }

    enum Failure: Error, Equatable {
        case cantVerifyInstalled
        case download(String)
        case unsupportedFormat(String)
        case appNotFound
        case wrongDeveloper
        case invalidSignature
        case notNewer
        case stillRunning
        /// macOS App Management blocked replacing the app.
        case needsAppManagement
        /// The app belongs to the system account (installed for all users).
        case needsPassword
        case failed(String)

        var message: String {
            switch self {
            case .cantVerifyInstalled: "The installed app isn't signed by a verified developer, so there's no way to check an update comes from the same place. Download it from the developer instead."
            case .download(let reason): "Download failed: \(reason)"
            case .unsupportedFormat(let kind): "This update comes as a \(kind), which Mac Vitals doesn't install. Download it from the developer instead."
            case .appNotFound: "The download didn't contain this app."
            case .wrongDeveloper: "The update is signed by a different developer than the installed app, so Mac Vitals didn't install it."
            case .invalidSignature: "The update's signature doesn't check out, so Mac Vitals didn't install it."
            case .notNewer: "The download isn't newer than what's installed."
            case .stillRunning: "The app didn't quit. Quit it and try again."
            case .needsAppManagement: "macOS needs your OK before Mac Vitals can replace apps."
            case .needsPassword: "This app was installed for all users, so replacing it needs your password."
            case .failed(let reason): reason
            }
        }
    }

    /// A verified new copy, ready to put in place (kept if replacing needs a permission first).
    struct Staged: Sendable {
        let newApp: URL
        let workDirectory: URL
    }

    // MARK: Download + verify

    static func stage(_ app: UpdatableApp, from url: URL, progress: @escaping @Sendable (Step) -> Void) async throws -> Staged {
        guard app.teamID != nil else { throw Failure.cantVerifyInstalled }
        guard url.scheme == "https" else { throw Failure.download("insecure link") }
        let work = FileManager.default.temporaryDirectory.appending(path: "MacVitals-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let archive = try await download(url, into: work, progress: progress)
            progress(.verifying)
            let extracted = work.appending(path: "extracted")
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try extract(archive, into: extracted)
            guard let newApp = findApp(bundleID: app.bundleID, in: extracted) else { throw Failure.appNotFound }
            try verify(newApp, replacing: app)
            return Staged(newApp: newApp, workDirectory: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Step) -> Void
        var observation: NSKeyValueObservation?
        init(report: @escaping @Sendable (Step) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
                report(.downloading(progress.fractionCompleted))
            }
        }
    }

    private static func download(_ url: URL, into work: URL, progress: @escaping @Sendable (Step) -> Void) async throws -> URL {
        progress(.downloading(0))
        let delegate = ProgressDelegate(report: progress)
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        delegate.observation = nil
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.download("the server answered \(http.statusCode)")
        }
        let name = response.suggestedFilename ?? url.lastPathComponent
        let destination = work.appending(path: name.isEmpty ? "update" : name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    // MARK: Extract

    static func archiveKind(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return "zip" }
        if lower.hasSuffix(".dmg") { return "dmg" }
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.xz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar") { return "tar" }
        if lower.hasSuffix(".pkg") || lower.hasSuffix(".mpkg") { return "pkg" }
        return nil
    }

    private static func extract(_ archive: URL, into destination: URL) throws {
        switch archiveKind(archive.lastPathComponent) {
        case "zip":
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path])
        case "tar":
            try run("/usr/bin/tar", ["-xf", archive.path, "-C", destination.path])
        case "dmg":
            let mount = destination.deletingLastPathComponent().appending(path: "mount")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            // "Y" answers the license prompt some disk images show.
            try run("/usr/bin/hdiutil", ["attach", archive.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path], input: "Y\n")
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            for item in (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
            where item.pathExtension == "app" {
                try run("/usr/bin/ditto", [item.path, destination.appending(path: item.lastPathComponent).path])
            }
        case "pkg":
            throw Failure.unsupportedFormat("installer package")
        default:
            throw Failure.unsupportedFormat("file Mac Vitals doesn't recognize")
        }
    }

    static func findApp(bundleID: String?, in folder: URL, depth: Int = 0) -> URL? {
        guard depth < 3, let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for item in contents where item.pathExtension == "app" {
            if Bundle(url: item)?.bundleIdentifier == bundleID { return item }
        }
        for item in contents where item.hasDirectoryPath && item.pathExtension != "app" {
            if let found = findApp(bundleID: bundleID, in: item, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: Verify

    /// Full signature check (every file), same Team ID as the installed app, and actually newer.
    static func verify(_ newApp: URL, replacing app: UpdatableApp) throws {
        guard let team = app.teamID else { throw Failure.cantVerifyInstalled }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            throw Failure.invalidSignature
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { throw Failure.invalidSignature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let result = SecStaticCodeCheckValidity(code, flags, requirement)
        if result == errSecCSReqFailed { throw Failure.wrongDeveloper }
        guard result == errSecSuccess else { throw Failure.invalidSignature }

        let info = Bundle(url: newApp)?.infoDictionary ?? [:]
        let newBuild = info["CFBundleVersion"] as? String
        let newVersion = info["CFBundleShortVersionString"] as? String ?? newBuild ?? "0"
        let isNewer = if let newBuild, let build = app.build { VersionComparator.isNewer(newBuild, than: build) }
            else { VersionComparator.isNewer(newVersion, than: app.version) }
        guard isNewer else { throw Failure.notNewer }
    }

    // MARK: Install

    /// Quits the app if needed, moves the old version to the Trash and puts the new one in
    /// its place. On any failure after the old one moved, it's put back.
    @MainActor
    static func install(_ staged: Staged, over app: UpdatableApp, viaFinder: Bool = false) async throws {
        let target = URL(fileURLWithPath: app.path)
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }
        let wasRunning = !running.isEmpty
        running.forEach { $0.terminate() }
        for _ in 0..<40 where running.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(250)) }
        guard running.allSatisfy(\.isTerminated) else { throw Failure.stillRunning }

        let newApp = staged.newApp
        try await Task.detached(priority: .userInitiated) {
            var trashedOld: URL?
            if viaFinder {
                let item = FailedItem(name: app.name, path: app.path, size: 0, blocker: .admin)
                let result = FinderRemover.trash([item])
                guard result.remaining.isEmpty else { throw Failure.needsPassword }
                trashedOld = result.entries.first?.trashedPath.map(URL.init(fileURLWithPath:))
            } else {
                do {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
                    trashedOld = resulting as URL?
                } catch {
                    switch CleanupRemover.blocker(for: error, path: app.path, hasFullDiskAccess: true) {
                    case .appManagement: throw Failure.needsAppManagement
                    case .admin: throw Failure.needsPassword
                    default: throw Failure.failed(error.localizedDescription)
                    }
                }
            }
            do {
                try FileManager.default.moveItem(at: newApp, to: target)
            } catch {
                if let trashedOld { try? FileManager.default.moveItem(at: trashedOld, to: target) }
                throw Failure.failed("Couldn't put the new version in place, so the old one was restored. (\(error.localizedDescription))")
            }
        }.value
        try? FileManager.default.removeItem(at: staged.workDirectory)
        if wasRunning {
            NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    // MARK: Helpers

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)); try? stdin.fileHandleForWriting.close() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure.failed("\((executable as NSString).lastPathComponent) failed: \(text.split(separator: "\n").last.map(String.init) ?? "")")
        }
        return text
    }
}
