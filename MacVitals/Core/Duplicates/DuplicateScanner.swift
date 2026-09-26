import Foundation
import Darwin
import CryptoKit
import Synchronization
import UniformTypeIdentifiers

/// One file that has an identical twin somewhere.
struct DuplicateFile: Identifiable, Hashable, Sendable {
    let path: String
    /// Length of the contents in bytes (what's compared).
    let size: Int64
    /// Space it would free if removed: the part of it not shared with another copy.
    /// A Finder duplicate (⌘D) shares its data with the original on APFS, so this can be 0.
    var privateSize: Int64
    let modified: Date
    let created: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var isInICloudDrive: Bool { path.contains("/Library/Mobile Documents/") }
}

/// Files with byte-for-byte identical contents.
struct DuplicateGroup: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case photos, videos, music, documents, archives, other

        var title: String {
            switch self {
            case .photos: "Photos"
            case .videos: "Videos"
            case .music: "Music"
            case .documents: "Documents"
            case .archives: "Archives"
            case .other: "Other"
            }
        }

        var icon: String {
            switch self {
            case .photos: "photo"
            case .videos: "film"
            case .music: "music.note"
            case .documents: "doc.text"
            case .archives: "archivebox"
            case .other: "doc"
            }
        }

        static func of(_ path: String) -> Kind {
            guard let type = UTType(filenameExtension: (path as NSString).pathExtension.lowercased()) else { return .other }
            if type.conforms(to: .image) { return .photos }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
            if type.conforms(to: .audio) { return .music }
            if type.conforms(to: .archive) || type.conforms(to: .diskImage) || type.identifier == "com.apple.installer-package-archive" { return .archives }
            if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet) || type.conforms(to: .content) { return .documents }
            return .other
        }
    }

    /// Content fingerprint (SHA-256).
    let id: String
    var files: [DuplicateFile]
    var kind: Kind { Kind.of(files.first?.path ?? "") }
    var size: Int64 { files.first?.size ?? 0 }

    /// Every copy already shares its data with the others (e.g. Finder duplicates on APFS):
    /// removing copies frees nothing.
    var sharesSpace: Bool { files.dropFirst().allSatisfy { $0.privateSize < max(4096, $0.size / 20) } }
}

/// Finds exact duplicates: size first (free), then the first and last 64 KB, then the whole
/// file. Only files that match byte for byte (SHA-256) are reported, never guesses by name.
final class DuplicateScanner: @unchecked Sendable {
    enum Stage: Equatable, Sendable { case listing, comparing }

    let filesListed = Atomic<Int>(0)
    let bytesToCompare = Atomic<Int64>(0)
    let bytesCompared = Atomic<Int64>(0)
    let stage = Mutex<Stage>(.listing)
    private let cancelled = Atomic<Bool>(false)

    func cancel() { cancelled.store(true, ordering: .relaxed) }
    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Folders whose insides belong to an app or a project, not loose files you manage.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band",
        "aplibrary", "lrlibrary", "lrdata", "xcodeproj", "xcworkspace", "xcassets", "bundle", "framework", "plugin",
        "kext", "appex", "playground", "pages", "numbers", "key", "rtfd", "photoboothlibrary", "sparsebundle",
        "vmwarevm", "pvm", "utm", "xcarchive", "docarchive", "abbu", "mbox", "nib", "scptd",
    ]
    /// Folders full of deliberate copies (dependencies, build output).
    static let skippedFolderNames: Set<String> = ["node_modules", "Pods", "DerivedData", "bower_components", "vendor", "__pycache__"]

    static func defaultFolders(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    struct Entry {
        let path: String
        let size: Int64
        let fileID: UInt64
        let modified: Date
        let created: Date
    }

    // MARK: Scan

    func scan(folders: [String], minimumSize: Int64) async -> [DuplicateGroup] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.scanSync(folders: folders, minimumSize: minimumSize))
            }
        }
    }

    func scanSync(folders: [String], minimumSize: Int64) -> [DuplicateGroup] {
        // 1. List files, grouped by exact size. Hard links (same file, two names) collapse to one.
        var bySize: [Int64: [Entry]] = [:]
        var seen: Set<UInt64> = []
        var visitedRoots: Set<String> = []
        for folder in folders {
            let resolved = (folder as NSString).resolvingSymlinksInPath
            // Nested selections (Documents and Documents/Work) are listed once.
            guard !visitedRoots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) else { continue }
            visitedRoots.insert(resolved)
            walk(resolved, minimumSize: minimumSize) { entry in
                guard seen.insert(entry.fileID).inserted else { return }
                bySize[entry.size, default: []].append(entry)
            }
            if isCancelled { return [] }
        }
        let candidates = bySize.values.filter { $0.count > 1 }
        stage.withLock { $0 = .comparing }
        bytesToCompare.store(candidates.reduce(0) { $0 + $1.reduce(0) { $0 + min($1.size, 128 * 1024) } }, ordering: .relaxed)

        // 2. First + last 64 KB, then 3. the whole file, in parallel across size groups.
        let results = Mutex<[DuplicateGroup]>([])
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            guard !isCancelled else { return }
            for group in confirmDuplicates(candidates[index]) { results.withLock { $0.append(group) } }
        }
        guard !isCancelled else { return [] }
        return results.withLock { $0 }.map { group in
            var group = group
            group.files = group.files.map { file in
                var file = file
                file.privateSize = Self.privateSize(file.path) ?? file.privateSize
                return file
            }
            return group
        }
    }

    private func confirmDuplicates(_ sameSize: [Entry]) -> [DuplicateGroup] {
        let size = sameSize[0].size
        var byEnds: [String: [Entry]] = [:]
        for entry in sameSize {
            guard let digest = Self.hash(entry.path, size: size, partial: true) else { continue }
            bytesCompared.add(min(size, 128 * 1024), ordering: .relaxed)
            byEnds[digest, default: []].append(entry)
        }
        var groups: [DuplicateGroup] = []
        for (endsDigest, matching) in byEnds where matching.count > 1 {
            // Small files were read completely by the partial pass.
            let needsFull = size > 128 * 1024
            var byContent: [String: [Entry]] = [:]
            if needsFull {
                bytesToCompare.add(Int64(matching.count) * size, ordering: .relaxed)
                for entry in matching {
                    guard !isCancelled, let digest = Self.hash(entry.path, size: size, partial: false, onBytes: { self.bytesCompared.add(Int64($0), ordering: .relaxed) }) else { continue }
                    byContent[digest, default: []].append(entry)
                }
            } else {
                byContent[endsDigest] = matching // already the whole file
            }
            for (digest, entries) in byContent where entries.count > 1 {
                groups.append(DuplicateGroup(id: digest, files: entries.map {
                    DuplicateFile(path: $0.path, size: $0.size, privateSize: $0.size, modified: $0.modified, created: $0.created)
                }))
            }
        }
        return groups
    }

    // MARK: Hashing

    static let endLength = 64 * 1024

    /// SHA-256 of the first and last 64 KB (partial) or the whole file.
    static func hash(_ path: String, size: Int64, partial: Bool, onBytes: ((Int) -> Void)? = nil) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            if partial {
                if let head = try handle.read(upToCount: endLength) { hasher.update(data: head) }
                if size > Int64(endLength * 2) {
                    try handle.seek(toOffset: UInt64(size) - UInt64(endLength))
                    if let tail = try handle.read(upToCount: endLength) { hasher.update(data: tail) }
                } else if let rest = try handle.read(upToCount: endLength) {
                    hasher.update(data: rest)
                }
            } else {
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    onBytes?(chunk.count)
                }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes of this file not shared with a clone (APFS). nil if the volume can't say.
    static func privateSize(_ path: String) -> Int64? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &attributes, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int64? in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: Int64.self)
        }
    }

    // MARK: Listing (getattrlistbulk)

    private func walk(_ folder: String, minimumSize: Int64, found: (Entry) -> Void) {
        var pending = [folder]
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        while let directory = pending.popLast() {
            guard !isCancelled else { return }
            let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            var files: [Entry] = []
            var subfolders: [String] = []
            var isRepository = false
            list(fd, buffer: buffer) { name, isDirectory, entry in
                if name == ".git" { isRepository = true }
                if name.hasPrefix(".") { return } // hidden files and folders
                let path = (directory as NSString).appendingPathComponent(name)
                if isDirectory {
                    let ext = (name as NSString).pathExtension.lowercased()
                    guard !Self.packageExtensions.contains(ext), !Self.skippedFolderNames.contains(name) else { return }
                    subfolders.append(path)
                } else if let entry, entry.size >= minimumSize {
                    files.append(Entry(path: path, size: entry.size, fileID: entry.fileID, modified: entry.modified, created: entry.created))
                }
            }
            close(fd)
            // A code repository: its files are managed by git, and removing any breaks it.
            guard !isRepository else { continue }
            filesListed.add(files.count, ordering: .relaxed)
            files.forEach(found)
            pending.append(contentsOf: subfolders)
        }
    }

    private struct RawFile {
        let size: Int64
        let fileID: UInt64
        let modified: Date
        let created: Date
    }

    private func list(_ fd: Int32, buffer: UnsafeMutableRawPointer, each: (String, Bool, RawFile?) -> Void) {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        attributes.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, 256 * 1024, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count <= 0 { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                // Order: length · returned · name · objtype · crtime · modtime · flags · fileid · datalength
                var cursor = entry + 4 + MemoryLayout<attribute_set_t>.size
                let nameRef = cursor
                let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
                cursor += MemoryLayout<attrreference_t>.size
                let objectType = cursor.loadUnaligned(as: UInt32.self); cursor += 4
                let created = cursor.loadUnaligned(as: timespec.self); cursor += MemoryLayout<timespec>.size
                let modified = cursor.loadUnaligned(as: timespec.self); cursor += MemoryLayout<timespec>.size
                let flags = cursor.loadUnaligned(as: UInt32.self); cursor += 4
                let fileID = cursor.loadUnaligned(as: UInt64.self); cursor += 8
                let dataLength = cursor.loadUnaligned(as: Int64.self)
                let name = String(cString: (nameRef + nameOffset).assumingMemoryBound(to: CChar.self))

                switch objectType {
                case UInt32(VDIR.rawValue):
                    each(name, true, nil)
                case UInt32(VREG.rawValue):
                    // Not downloaded from iCloud: takes no space here, and reading it would download it.
                    if flags & UInt32(SF_DATALESS) == 0 {
                        each(name, false, RawFile(size: dataLength, fileID: fileID,
                                                  modified: Date(timeIntervalSince1970: Double(modified.tv_sec)),
                                                  created: Date(timeIntervalSince1970: Double(created.tv_sec))))
                    }
                default:
                    break
                }
                entry += length
            }
        }
    }
}
