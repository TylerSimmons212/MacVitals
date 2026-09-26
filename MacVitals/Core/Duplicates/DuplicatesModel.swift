import Foundation
import AppKit
import Observation

/// Picks which copy to keep, the way a person would: the one in a proper place (Documents,
/// Pictures…) over Downloads or the Desktop, the original name over "photo copy" or
/// "photo (1)", and the older file over the newer.
enum KeepChooser {
    static func keeper(of files: [DuplicateFile], home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> DuplicateFile? {
        files.max { score($0, among: files, home: home).lexicographicallyPrecedes(score($1, among: files, home: home)) }
    }

    /// Higher is better. Compared in order: location, clean name, age, shallow path.
    static func score(_ file: DuplicateFile, among files: [DuplicateFile], home: String) -> [Double] {
        [
            locationRank(file.path, home: home),
            isCopyName(file, among: files) ? 0 : 1,
            -file.created.timeIntervalSince1970,
            -Double(file.path.split(separator: "/").count),
            -Double(file.name.count),
        ]
    }

    static func locationRank(_ path: String, home: String) -> Double {
        let lasting = ["Documents", "Pictures", "Movies", "Music", "Library/Mobile Documents"].map { home + "/" + $0 + "/" }
        if lasting.contains(where: path.hasPrefix) { return 3 }
        if path.hasPrefix(home + "/Downloads/") { return 1 }
        if path.hasPrefix(home + "/Desktop/") { return 2 }
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/") { return 0 }
        return 2
    }

    /// "Report copy.pdf", "Report copy 2.pdf", "Report (1).pdf", "Report-2.pdf", "Report 2.pdf",
    /// but only when a copy without that ending is in the same group (so "Trip 2" alone is fine).
    static func isCopyName(_ file: DuplicateFile, among files: [DuplicateFile]) -> Bool {
        let stem = ((file.name as NSString).deletingPathExtension)
        guard let range = stem.range(of: #"( copy( \d+)?| \(\d+\)|[- ]\d{1,2})$"#, options: [.regularExpression, .caseInsensitive]) else { return false }
        let base = String(stem[..<range.lowerBound])
        return files.contains { $0.path != file.path && ($0.name as NSString).deletingPathExtension == base }
    }
}

@MainActor
@Observable
final class DuplicatesModel {
    enum Phase: Equatable { case idle, scanning, ready }

    private(set) var phase: Phase = .idle
    private(set) var groups: [DuplicateGroup] = []
    /// Paths chosen to move to the Trash.
    private(set) var selected: Set<String> = []
    private(set) var folders: [String]
    var minimumSize: Int64 {
        didSet { UserDefaults.standard.set(minimumSize, forKey: Self.minimumSizeKey) }
    }
    var kindFilter: DuplicateGroup.Kind?
    var showSharedSpace = false

    private(set) var filesListed = 0
    private(set) var comparing = false
    private(set) var compareFraction: Double = 0
    private(set) var scanDuration: TimeInterval = 0
    private(set) var scanDate: Date?

    @ObservationIgnored private var scanner: DuplicateScanner?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    static let foldersKey = "duplicates.folders"
    static let minimumSizeKey = "duplicates.minimumSize"
    static let sizeOptions: [(Int64, String)] = [(100_000, "100 KB"), (1_000_000, "1 MB"), (10_000_000, "10 MB"), (100_000_000, "100 MB")]

    init() {
        folders = UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? DuplicateScanner.defaultFolders()
        let stored = UserDefaults.standard.object(forKey: Self.minimumSizeKey) as? NSNumber
        minimumSize = stored?.int64Value ?? 1_000_000
    }

    // MARK: Derived

    /// Groups worth showing: matching the filter, and (unless asked) not ones that already share space.
    var visibleGroups: [DuplicateGroup] {
        groups.filter { (kindFilter == nil || $0.kind == kindFilter) && (showSharedSpace || !$0.sharesSpace) }
            .sorted { potential($0) > potential($1) }
    }

    var sharedSpaceGroups: Int { groups.filter(\.sharesSpace).count }
    func count(of kind: DuplicateGroup.Kind?) -> Int {
        groups.filter { (kind == nil || $0.kind == kind) && (showSharedSpace || !$0.sharesSpace) }.count
    }

    /// Space removing every copy but the keeper would free.
    func potential(_ group: DuplicateGroup) -> Int64 {
        guard let keeper = KeepChooser.keeper(of: group.files) else { return 0 }
        return group.files.filter { $0.path != keeper.path }.reduce(0) { $0 + $1.privateSize }
    }

    var totalPotential: Int64 { groups.filter { !$0.sharesSpace }.reduce(0) { $0 + potential($1) } }
    var extraCopies: Int { groups.filter { !$0.sharesSpace }.reduce(0) { $0 + $1.files.count - 1 } }
    var selectedFiles: [DuplicateFile] { groups.flatMap(\.files).filter { selected.contains($0.path) } }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.privateSize } }

    func isSelected(_ file: DuplicateFile) -> Bool { selected.contains(file.path) }

    /// You can't select every copy in a group: one always stays.
    func canSelect(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        isSelected(file) || group.files.filter { !isSelected($0) }.count > 1
    }

    // MARK: Selection

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if selected.contains(file.path) {
            selected.remove(file.path)
        } else if canSelect(file, in: group) {
            selected.insert(file.path)
        }
    }

    /// Every copy but the one worth keeping, in groups where removing actually frees space.
    func autoSelect() {
        var picks: Set<String> = []
        for group in groups where !group.sharesSpace {
            guard let keeper = KeepChooser.keeper(of: group.files) else { continue }
            for file in group.files where file.path != keeper.path { picks.insert(file.path) }
        }
        selected = picks
    }

    func deselectAll() { selected = [] }

    // MARK: Folders

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search for duplicates"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
        saveFolders()
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        saveFolders()
    }

    func resetFolders() {
        folders = DuplicateScanner.defaultFolders()
        saveFolders()
    }

    private func saveFolders() { UserDefaults.standard.set(folders, forKey: Self.foldersKey) }

    // MARK: Scanning

    func scan() async {
        cancel()
        phase = .scanning
        filesListed = 0
        comparing = false
        compareFraction = 0
        let scanner = DuplicateScanner()
        self.scanner = scanner
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.filesListed = scanner.filesListed.load(ordering: .relaxed)
                self.comparing = scanner.stage.withLock { $0 } == .comparing
                let total = scanner.bytesToCompare.load(ordering: .relaxed)
                self.compareFraction = total > 0 ? min(0.99, Double(scanner.bytesCompared.load(ordering: .relaxed)) / Double(total)) : 0
            }
        }
        let started = Date()
        let found = await scanner.scan(folders: folders, minimumSize: minimumSize)
        progressTask?.cancel()
        guard !scanner.isCancelled else { return }
        filesListed = scanner.filesListed.load(ordering: .relaxed)
        scanDuration = Date().timeIntervalSince(started)
        scanDate = Date()
        load(found)
    }

    func cancel() {
        scanner?.cancel()
        scanner = nil
        progressTask?.cancel()
        if phase == .scanning { phase = groups.isEmpty && scanDate == nil ? .idle : .ready }
    }

    /// Shows results (used after a scan, and by tests).
    func load(_ found: [DuplicateGroup]) {
        groups = found
        autoSelect()
        phase = .ready
    }

    // MARK: Removing

    func removeSelected(engine: CleanupEngine) async {
        let files = selectedFiles
        guard !files.isEmpty else { return }
        let items = files.map { JunkItem(path: $0.path, name: $0.name, detail: $0.folder, size: $0.privateSize, tier: .review) }
        let record = await Task.detached(priority: .userInitiated) {
            CleanupRemover.remove(items, permanently: false)
        }.value
        engine.record(record)
        let removed = Set(record.entries.map(\.originalPath))
        groups = groups.compactMap { group in
            var group = group
            group.files.removeAll { removed.contains($0.path) }
            return group.files.count > 1 ? group : nil
        }
        selected.subtract(removed)
        selected = selected.filter { path in groups.contains { $0.files.contains { $0.path == path } } }
    }
}
