import Foundation

/// Plain-language storage categories, like Apple's Storage settings, plus "Developer",
/// which is often the biggest surprise on a developer's Mac.
enum StorageKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case apps, documents, downloads, media, developer, backups, mail, caches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Apps"
        case .documents: "Documents & Desktop"
        case .downloads: "Downloads"
        case .media: "Photos, Music & Movies"
        case .developer: "Developer"
        case .backups: "iPhone & iPad Backups"
        case .mail: "Mail & Messages"
        case .caches: "Caches & Logs"
        }
    }

    var icon: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .documents: "doc.text"
        case .downloads: "arrow.down.circle"
        case .media: "photo.on.rectangle"
        case .developer: "hammer"
        case .backups: "iphone"
        case .mail: "envelope"
        case .caches: "archivebox"
        }
    }

    /// One line for non-technical people: what this is and whether it's safe to shrink.
    var explanation: String {
        switch self {
        case .apps: "Installed apps. Delete ones you don't use."
        case .documents: "Your files on the Desktop and in Documents."
        case .downloads: "Everything you've downloaded. Often full of old installers."
        case .media: "Photos library, music and videos."
        case .developer: "Xcode data, simulators, package caches and projects."
        case .backups: "Old iPhone/iPad backups. Safe to delete ones you don't need."
        case .mail: "Mail and Messages, including attachments."
        case .caches: "Temporary files apps rebuild automatically. Safe to clean."
        }
    }

    /// Protected by Full Disk Access (vs. the per-folder prompts for Documents/Desktop/Downloads).
    var needsFullDiskAccess: Bool {
        self == .backups || self == .mail
    }

    /// Where to measure. `expand` = list this folder's children individually as "largest items".
    fileprivate func roots(home: URL) -> [(url: URL, expand: Bool)] {
        let library = home.appending(path: "Library")
        switch self {
        case .apps:
            return [(URL(fileURLWithPath: "/Applications"), true), (home.appending(path: "Applications"), true)]
        case .documents:
            return [(home.appending(path: "Documents"), true), (home.appending(path: "Desktop"), true)]
        case .downloads:
            return [(home.appending(path: "Downloads"), true)]
        case .media:
            return [(home.appending(path: "Pictures"), true), (home.appending(path: "Music"), true), (home.appending(path: "Movies"), true)]
        case .developer:
            return [
                (library.appending(path: "Developer"), true),
                (home.appending(path: "Developer"), true),
                (library.appending(path: "Containers/com.docker.docker"), false),
                (home.appending(path: ".docker"), false),
                (home.appending(path: ".npm"), false),
                (home.appending(path: ".gradle"), false),
                (home.appending(path: ".cargo"), false),
                (home.appending(path: ".rustup"), false),
                (home.appending(path: ".bun"), false),
                (home.appending(path: ".cocoapods"), false),
                (library.appending(path: "Android/sdk"), false),
            ]
        case .backups:
            return [(library.appending(path: "Application Support/MobileSync/Backup"), true)]
        case .mail:
            return [(library.appending(path: "Mail"), false), (library.appending(path: "Messages"), false)]
        case .caches:
            return [(library.appending(path: "Caches"), true), (library.appending(path: "Logs"), false)]
        }
    }

    /// Big individual files are only worth listing where the user can act on them.
    fileprivate var collectsLargeFiles: Bool {
        switch self {
        case .documents, .downloads, .media, .developer: true
        case .apps, .backups, .mail, .caches: false
        }
    }
}

struct StorageItem: Codable, Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let size: Int64
    var id: String { path }
}

struct StorageCategory: Codable, Identifiable, Sendable {
    let kind: StorageKind
    let size: Int64
    /// Largest folders/apps inside this category, biggest first.
    let largest: [StorageItem]
    /// macOS privacy settings blocked us from measuring (some or all of) it.
    let needsAccess: Bool
    var id: StorageKind { kind }
}

struct StorageReport: Codable, Sendable {
    let scannedAt: Date
    let categories: [StorageCategory]
    let largestFiles: [StorageItem]

    var measuredTotal: Int64 { categories.reduce(0) { $0 + $1.size } }

    /// Whatever we didn't measure: macOS itself, system data, other users, hidden files.
    func systemAndOther(used: Int64) -> Int64 { max(0, used - measuredTotal) }
}

enum StorageScanner {
    static let largeFileThreshold: Int64 = 200_000_000
    static let largestItemsPerCategory = 6
    static let largestFileCount = 10

    /// File trees that are opaque to the user; individual files inside aren't actionable.
    private static let opaquePackageMarkers = [".app/", ".photoslibrary/", ".musiclibrary/", ".tvlibrary/",
                                               ".fcpbundle/", ".imovielibrary/", ".xcarchive/", ".logicx/"]

    struct Result: Sendable {
        let category: StorageCategory
        let bigFiles: [StorageItem]
    }

    static func scan(_ kind: StorageKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result {
        let fm = FileManager.default
        var total: Int64 = 0
        var items: [StorageItem] = []
        var bigFiles = TopItems(limit: largestFileCount)
        var needsAccess = false

        for root in kind.roots(home: home) where fm.fileExists(atPath: root.url.path) {
            if root.expand {
                let children: [URL]
                do {
                    children = try fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil, options: [])
                } catch {
                    needsAccess = true
                    continue
                }
                for child in children where child.lastPathComponent != ".DS_Store" {
                    let measured = measure(child, collect: kind.collectsLargeFiles, into: &bigFiles)
                    needsAccess = needsAccess || measured.denied
                    total += measured.size
                    if measured.size > 0 {
                        items.append(StorageItem(path: child.path, name: displayName(child, home: home), size: measured.size))
                    }
                }
            } else {
                let measured = measure(root.url, collect: kind.collectsLargeFiles, into: &bigFiles)
                needsAccess = needsAccess || measured.denied
                total += measured.size
                if measured.size > 0 {
                    items.append(StorageItem(path: root.url.path, name: displayName(root.url, home: home), size: measured.size))
                }
            }
        }

        let largest = Array(items.sorted { $0.size > $1.size }.prefix(largestItemsPerCategory))
        return Result(
            category: StorageCategory(kind: kind, size: total, largest: largest, needsAccess: needsAccess),
            bigFiles: bigFiles.items
        )
    }

    /// Allocated size of a file or folder tree, noting permission failures and big files on the way.
    static func measure(_ url: URL, collect: Bool, into bigFiles: inout TopItems) -> (size: Int64, denied: Bool) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, false) }
        if values.isDirectory != true {
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if collect { considerLargeFile(url, size: size, into: &bigFiles) }
            return (size, false)
        }
        var denied = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                let code = (error as NSError).code
                if code == NSFileReadNoPermissionError || (error as NSError).underlyingErrors.contains(where: { ($0 as NSError).code == Int(EPERM) || ($0 as NSError).code == Int(EACCES) }) {
                    denied = true
                }
                return true
            }
        ) else { return (0, true) }

        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            total += size
            if collect { considerLargeFile(file, size: size, into: &bigFiles) }
        }
        return (total, denied)
    }

    private static func considerLargeFile(_ url: URL, size: Int64, into bigFiles: inout TopItems) {
        guard size >= largeFileThreshold else { return }
        let path = url.path
        guard !opaquePackageMarkers.contains(where: { path.contains($0) }) else { return }
        bigFiles.insert(StorageItem(path: path, name: url.lastPathComponent, size: size))
    }

    static func displayName(_ url: URL, home: URL) -> String {
        let name = url.lastPathComponent
        if name.hasSuffix(".app") { return String(name.dropLast(4)) }
        // Resolve symlinks on both sides (e.g. /var → /private/var) so the ~ shortening matches.
        let path = url.resolvingSymlinksInPath().path
        let homePath = home.resolvingSymlinksInPath().path
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    // MARK: Cache

    static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MacVitals/storage.json")
    }

    static func loadCached(from url: URL = cacheURL) -> StorageReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StorageReport.self, from: data)
    }

    static func save(_ report: StorageReport, to url: URL = cacheURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: url, options: .atomic) }
    }
}

/// Keeps the N largest items seen, cheaply.
struct TopItems: Sendable {
    let limit: Int
    private(set) var items: [StorageItem] = []

    init(limit: Int) { self.limit = limit }

    mutating func insert(_ item: StorageItem) {
        if items.count < limit {
            items.append(item)
        } else if let smallest = items.last, item.size > smallest.size {
            items[items.count - 1] = item
        } else {
            return
        }
        items.sort { $0.size > $1.size }
    }

    mutating func merge(_ other: [StorageItem]) {
        for item in other { insert(item) }
    }
}
