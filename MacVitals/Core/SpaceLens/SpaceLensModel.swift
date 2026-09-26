import Foundation
import AppKit
import Observation

/// Space Lens: scan a folder (or the whole Mac) into a size tree, then explore it.
/// The tree lives for the session; scanning again replaces it.
@MainActor
@Observable
final class SpaceLensModel {
    enum Target: Equatable, Hashable {
        case home
        case wholeMac
        case folder(String)

        var path: String {
            switch self {
            case .home: FileManager.default.homeDirectoryForCurrentUser.path
            // The Data volume: where everything that's yours (and apps' data) lives.
            case .wholeMac: "/System/Volumes/Data"
            case .folder(let path): path
            }
        }

        var title: String {
            switch self {
            case .home: "Home folder"
            case .wholeMac: "Macintosh HD"
            case .folder(let path): FileManager.default.displayName(atPath: path)
            }
        }
    }

    enum Phase: Equatable { case idle, scanning, ready }

    private(set) var phase: Phase = .idle
    private(set) var target: Target = .home
    private(set) var root: SpaceNode?
    /// The folder at the center of the chart.
    private(set) var current: SpaceNode?
    private(set) var filesScanned = 0
    private(set) var bytesScanned: Int64 = 0
    private(set) var unreadableFolders = 0
    private(set) var scanDate: Date?
    private(set) var scanDuration: TimeInterval = 0
    /// Expected total, for a progress fraction (known for the whole Mac; estimated otherwise).
    private(set) var expectedBytes: Int64?
    /// Bumped when the tree changes in place (items moved to the Trash) so views redraw.
    private(set) var revision = 0

    @ObservationIgnored private var scanner: SpaceScanner?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    var progress: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(0.99, Double(bytesScanned) / Double(expectedBytes))
    }

    func scan(_ target: Target) async {
        cancel()
        self.target = target
        phase = .scanning
        filesScanned = 0
        bytesScanned = 0
        unreadableFolders = 0
        let usedOnDisk = Self.usedSpace()
        // Whole Mac: the disk's used space. Otherwise: what this folder measured last time.
        expectedBytes = target == .wholeMac ? usedOnDisk : Self.lastSize(of: target.path)

        let scanner = SpaceScanner()
        self.scanner = scanner
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.filesScanned = scanner.filesScanned.load(ordering: .relaxed)
                self.bytesScanned = scanner.bytesScanned.load(ordering: .relaxed)
                self.unreadableFolders = scanner.unreadableFolders.load(ordering: .relaxed)
            }
        }

        let started = Date()
        let path = target.path
        // Other disks are mounted under /Volumes; they're not part of this one.
        let skip: Set<String> = target == .wholeMac ? [path + "/Volumes"] : []
        let tree = await scanner.scan(path, skipping: skip)
        progressTask?.cancel()
        guard !scanner.isCancelled else { return }

        if target == .wholeMac, let usedOnDisk, usedOnDisk > tree.size {
            let hidden = SpaceNode(name: "macOS and hidden space", kind: .hidden, size: usedOnDisk - tree.size)
            hidden.parent = tree
            tree.children.append(hidden)
            tree.children.sort { $0.size > $1.size }
            tree.size = usedOnDisk
        }
        filesScanned = scanner.filesScanned.load(ordering: .relaxed)
        bytesScanned = scanner.bytesScanned.load(ordering: .relaxed)
        unreadableFolders = scanner.unreadableFolders.load(ordering: .relaxed)
        scanDuration = Date().timeIntervalSince(started)
        Self.rememberSize(tree.size, of: path)
        scanDate = Date()
        root = tree
        current = tree
        phase = .ready
    }

    func cancel() {
        scanner?.cancel()
        scanner = nil
        progressTask?.cancel()
        if phase == .scanning { phase = root == nil ? .idle : .ready }
    }

    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to explore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await scan(.folder(url.path))
    }

    // MARK: Navigation

    func open(_ node: SpaceNode) {
        guard node.isFolder, !node.children.isEmpty else { return }
        current = node
    }

    func goUp() {
        if let parent = current?.parent { current = parent }
    }

    var canGoUp: Bool { current?.parent != nil }

    // MARK: Removing

    /// Moves an item to the Trash through the shared remover (so it shows in Clean Up history
    /// with Put Back), then takes it out of the tree.
    func trash(_ node: SpaceNode, engine: CleanupEngine) async {
        guard node.isReal, let parent = node.parent else { return }
        let item = JunkItem(path: node.path, name: node.name, detail: nil, size: node.size, tier: .review)
        let record = await Task.detached(priority: .userInitiated) {
            CleanupRemover.remove([item], permanently: false)
        }.value
        engine.record(record)
        if !record.entries.isEmpty {
            parent.remove(node)
            if current === node || (current.map { node.isAncestor(of: $0) } ?? false) { current = parent }
            revision &+= 1
        }
    }

    /// Why moving this might be a bad idea, in plain words (nil = ordinary personal files).
    nonisolated static func caution(for path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if CleanupRemover.isProtected(path) { return "This is part of macOS and can't be removed." }
        if path.hasSuffix(".app") { return "This is an app. The Uninstaller removes apps together with their leftover files." }
        if path.hasPrefix(home + "/Library") || path.hasPrefix("/Library") || path.hasPrefix("/System/Volumes/Data/Library") {
            return "This is in a Library folder, where apps keep settings and data they need. Only remove it if you know what it is."
        }
        if path.hasPrefix("/Applications") { return "This is inside an app. Removing parts of apps can break them." }
        return nil
    }

    nonisolated private static let lastSizesKey = "spaceLens.lastSizes"

    nonisolated static func lastSize(of path: String) -> Int64? {
        (UserDefaults.standard.dictionary(forKey: lastSizesKey)?[path] as? NSNumber)?.int64Value
    }

    nonisolated static func rememberSize(_ size: Int64, of path: String) {
        var sizes = UserDefaults.standard.dictionary(forKey: lastSizesKey) ?? [:]
        sizes[path] = NSNumber(value: size)
        UserDefaults.standard.set(sizes, forKey: lastSizesKey)
    }

    /// Space in use on the startup disk, counted the way the Finder does (including purgeable).
    nonisolated static func usedSpace() -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let size = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else { return nil }
        return size - free
    }
}
