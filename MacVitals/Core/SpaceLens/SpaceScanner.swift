import Foundation
import Darwin
import Synchronization

/// One folder or file in the size tree. Folders keep every subfolder and their largest files;
/// the rest of their files are summed into one "smaller files" entry, which keeps memory
/// bounded on trees with millions of files (node_modules, caches) without hiding anything big.
final class SpaceNode: Identifiable, @unchecked Sendable {
    enum Kind: Equatable, Sendable {
        case folder
        case file
        /// "1,204 smaller files": the files in a folder beyond its largest few.
        case smallFiles(count: Int)
        /// Whole-Mac view only: used space the scan couldn't attribute (macOS, snapshots, unreadable).
        case hidden
    }

    let name: String
    let kind: Kind
    var size: Int64
    /// Files inside (recursively), for folders.
    var fileCount: Int
    var children: [SpaceNode] = []
    weak var parent: SpaceNode?
    /// Couldn't be read (permissions); its size is unknown, counted as zero.
    var isUnreadable = false
    /// Root nodes carry their full path; everything else is parent path + name.
    private let rootPath: String?

    init(name: String, kind: Kind, size: Int64 = 0, fileCount: Int = 0, rootPath: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.rootPath = rootPath
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var isFolder: Bool { kind == .folder }
    var isReal: Bool { kind == .folder || kind == .file }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        return (parent.path as NSString).appendingPathComponent(name)
    }

    /// Root → … → self.
    var lineage: [SpaceNode] {
        var chain: [SpaceNode] = [self]
        var node = self
        while let parent = node.parent {
            chain.insert(parent, at: 0)
            node = parent
        }
        return chain
    }

    func isAncestor(of node: SpaceNode) -> Bool {
        var current = node.parent
        while let candidate = current {
            if candidate === self { return true }
            current = candidate.parent
        }
        return false
    }

    /// Removes a child and subtracts its size all the way up (after moving it to the Trash).
    func remove(_ child: SpaceNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        var node: SpaceNode? = self
        while let current = node {
            current.size -= child.size
            current.fileCount -= child.kind == .file ? 1 : child.fileCount
            node = current.parent
        }
    }
}

/// Fast size scanner built on `getattrlistbulk` (one system call returns a whole batch of
/// directory entries with their sizes), with folders scanned in parallel.
///
/// Sizes are *allocated* bytes (what the file really takes on disk), hard links are counted
/// once, other volumes mounted inside the tree are skipped, and nothing is followed through
/// symlinks.
final class SpaceScanner: @unchecked Sendable {
    let filesScanned = Atomic<Int>(0)
    let bytesScanned = Atomic<Int64>(0)
    let unreadableFolders = Atomic<Int>(0)
    /// A folder near the top that's being scanned right now (for "Now scanning…").
    let currentFolder = Mutex<String>("")
    private let cancelled = Atomic<Bool>(false)
    private let hardLinks = Mutex<Set<UInt64>>([])

    /// Largest files kept per folder; the rest are summed into one "smaller files" entry.
    static let filesKeptPerFolder = 12
    private static let bufferSize = 256 * 1024

    func cancel() { cancelled.store(true, ordering: .relaxed) }
    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Scans on GCD worker threads (blocking syscalls don't belong on Swift's cooperative pool).
    func scan(_ path: String, skipping: Set<String> = []) async -> SpaceNode {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.scanSync(path, skipping: skipping))
            }
        }
    }

    func scanSync(_ path: String, skipping: Set<String> = []) -> SpaceNode {
        let root = SpaceNode(name: (path as NSString).lastPathComponent, kind: .folder, rootPath: path)
        var rootStat = stat()
        guard stat(path, &rootStat) == 0 else {
            root.isUnreadable = true
            return root
        }
        fill(root, path: path, device: rootStat.st_dev, depth: 0, skipping: skipping)
        return root
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
        let size: Int64
    }

    /// Lists one folder, then recurses into its subfolders (in parallel near the top).
    private func fill(_ node: SpaceNode, path: String, device: dev_t, depth: Int, skipping: Set<String>) {
        guard !isCancelled else { return }
        if depth > 0 && depth <= 3 { currentFolder.withLock { $0 = path } }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            node.isUnreadable = true
            unreadableFolders.add(1, ordering: .relaxed)
            return
        }
        var folderStat = stat()
        if fstat(fd, &folderStat) == 0, folderStat.st_dev != device {
            close(fd) // another volume mounted here: not part of this disk
            return
        }
        let entries = listEntries(fd)
        close(fd)

        var subfolders: [SpaceNode] = []
        var files: [SpaceNode] = []
        var fileBytes: Int64 = 0
        for entry in entries {
            if entry.isDirectory {
                let childPath = (path as NSString).appendingPathComponent(entry.name)
                guard !skipping.contains(childPath) else { continue }
                subfolders.append(SpaceNode(name: entry.name, kind: .folder))
            } else {
                fileBytes += entry.size
                files.append(SpaceNode(name: entry.name, kind: .file, size: entry.size, fileCount: 1))
            }
        }
        filesScanned.add(files.count, ordering: .relaxed)
        bytesScanned.add(fileBytes, ordering: .relaxed)

        let recurse = { (child: SpaceNode) in
            self.fill(child, path: (path as NSString).appendingPathComponent(child.name), device: device, depth: depth + 1, skipping: skipping)
        }
        // Parallel wherever there's a choice of folders (GCD caps threads at the core count),
        // so one huge branch (iCloud Drive, node_modules) doesn't end up on a single thread.
        if depth < 12 && subfolders.count > 1 {
            DispatchQueue.concurrentPerform(iterations: subfolders.count) { recurse(subfolders[$0]) }
        } else {
            subfolders.forEach(recurse)
        }

        // Keep the biggest files individually; sum the rest.
        files.sort { $0.size > $1.size }
        var kept = Array(files.prefix(Self.filesKeptPerFolder))
        let rest = files.dropFirst(Self.filesKeptPerFolder)
        if !rest.isEmpty {
            kept.append(SpaceNode(name: "\(rest.count) smaller files", kind: .smallFiles(count: rest.count),
                                  size: rest.reduce(0) { $0 + $1.size }, fileCount: rest.count))
        }
        // Empty folders add nothing to the picture.
        let children = (subfolders + kept).filter { $0.size > 0 || $0.isUnreadable }
        for child in children { child.parent = node }
        node.children = children.sorted { $0.size > $1.size }
        node.size = fileBytes + subfolders.reduce(0) { $0 + $1.size }
        node.fileCount = files.count + subfolders.reduce(0) { $0 + $1.fileCount }
    }

    // MARK: getattrlistbulk

    private func listEntries(_ fd: Int32) -> [Entry] {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        attributes.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [Entry] = []
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count <= 0 { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                // With FSOPT_PACK_INVAL_ATTRS every requested attribute is present, in bit order:
                // length · returned attrs · name ref · object type · file id · link count · alloc size
                var cursor = entry + 4 + MemoryLayout<attribute_set_t>.size
                let nameRef = cursor
                let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
                let nameLength = Int(nameRef.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                cursor += MemoryLayout<attrreference_t>.size
                let objectType = cursor.loadUnaligned(as: UInt32.self)
                cursor += 4
                let fileID = cursor.loadUnaligned(as: UInt64.self)
                cursor += 8
                let linkCount = cursor.loadUnaligned(as: UInt32.self)
                cursor += 4
                let allocated = cursor.loadUnaligned(as: Int64.self)

                let namePointer = (nameRef + nameOffset).assumingMemoryBound(to: CChar.self)
                let name = String(cString: namePointer)
                _ = nameLength
                switch objectType {
                case UInt32(VDIR.rawValue):
                    entries.append(Entry(name: name, isDirectory: true, size: 0))
                case UInt32(VREG.rawValue):
                    var size = allocated
                    if linkCount > 1 {
                        let firstSighting = hardLinks.withLock { $0.insert(fileID).inserted }
                        if !firstSighting { size = 0 } // same data, already counted
                    }
                    entries.append(Entry(name: name, isDirectory: false, size: size))
                default:
                    break // symlinks, sockets, devices: no meaningful size, never followed
                }
                entry += length
            }
        }
        return entries
    }
}
