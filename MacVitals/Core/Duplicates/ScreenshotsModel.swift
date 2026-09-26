import Foundation
import AppKit
import Observation

/// One screenshot, from the Photos library or a file on disk.
struct Screenshot: Identifiable, Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        case library(String)
        case file(String)
    }

    let origin: Origin
    let date: Date
    let size: Int64?
    let pixelWidth: Int?
    let pixelHeight: Int?

    var id: String {
        switch origin {
        case .library(let id): "library:" + id
        case .file(let path): "file:" + path
        }
    }

    var path: String? { if case .file(let path) = origin { path } else { nil } }
}

/// Finds screenshots so going through them is quick: filter by age, select old ones in bulk,
/// or review one at a time with the keyboard.
@MainActor
@Observable
final class ScreenshotsModel {
    enum Source: String, CaseIterable { case library, files }
    enum Phase: Equatable { case idle, loading, ready }

    enum Age: String, CaseIterable, Identifiable {
        case all, week, month, olderThanMonth, olderThanYear
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .week: "This week"
            case .month: "This month"
            case .olderThanMonth: "Older than a month"
            case .olderThanYear: "Older than a year"
            }
        }

        func contains(_ date: Date, now: Date = Date()) -> Bool {
            let days = now.timeIntervalSince(date) / 86_400
            switch self {
            case .all: return true
            case .week: return days <= 7
            case .month: return days <= 31
            case .olderThanMonth: return days > 31
            case .olderThanYear: return days > 365
            }
        }
    }

    var source: Source {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "screenshots.source")
            selected = []
            Task { await load() }
        }
    }
    var age: Age = .all
    private(set) var phase: Phase = .idle
    private(set) var items: [Screenshot] = []
    private(set) var selected: Set<String> = []
    /// Review one at a time: the list being reviewed and where we are.
    private(set) var reviewList: [Screenshot] = []
    var reviewIndex: Int?

    init() {
        source = Source(rawValue: UserDefaults.standard.string(forKey: "screenshots.source") ?? "") ?? .library
    }

    var visible: [Screenshot] { items.filter { age.contains($0.date) } }
    var selectedItems: [Screenshot] { items.filter { selected.contains($0.id) } }
    var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + ($1.size ?? 0) } }
    func count(_ age: Age) -> Int { items.filter { age.contains($0.date) }.count }

    // MARK: Loading

    func load() async {
        phase = .loading
        switch source {
        case .library:
            guard PhotoLibrary.isAvailable else {
                items = []
                phase = .ready
                return
            }
            let assets = await Task.detached(priority: .userInitiated) { PhotoLibrary.screenshots() }.value
            items = assets.map { Screenshot(origin: .library($0.id), date: $0.date, size: $0.size,
                                            pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight) }
        case .files:
            var found = await Self.spotlightScreenshots()
            if found.isEmpty {
                found = await Task.detached(priority: .userInitiated) { Self.screenshotsByName() }.value
            }
            items = found.sorted { $0.date > $1.date }
        }
        selected = selected.filter { id in items.contains { $0.id == id } }
        phase = .ready
    }

    /// Where macOS saves screenshots (Screenshot app › Options › Save to), default Desktop.
    nonisolated static var saveFolder: String {
        let custom = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        return (custom.map { ($0 as NSString).expandingTildeInPath })
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop").path
    }

    /// macOS tags every screenshot file (kMDItemIsScreenCapture), whatever it's named.
    private static func spotlightScreenshots() async -> [Screenshot] {
        await withCheckedContinuation { continuation in
            let query = NSMetadataQuery()
            query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
                query.stop()
                var results: [Screenshot] = []
                for index in 0..<query.resultCount {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                          !path.contains("/Library/") else { continue }
                    let date = item.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date
                        ?? item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? .distantPast
                    results.append(Screenshot(origin: .file(path), date: date,
                                              size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                                              pixelWidth: item.value(forAttribute: NSMetadataItemPixelWidthKey) as? Int,
                                              pixelHeight: item.value(forAttribute: NSMetadataItemPixelHeightKey) as? Int))
                }
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: results)
            }
            if !query.start() {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: [])
            }
        }
    }

    /// Fallback when Spotlight is off: the save folder, by macOS's naming.
    nonisolated static func screenshotsByName(in folder: String = saveFolder) -> [Screenshot] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let contents = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys)) ?? []
        return contents.filter { isScreenshotName($0.lastPathComponent) }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Screenshot(origin: .file(url.path), date: values?.creationDate ?? .distantPast,
                              size: values?.fileSize.map(Int64.init), pixelWidth: nil, pixelHeight: nil)
        }
    }

    nonisolated static func isScreenshotName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let image = ["png", "jpg", "jpeg", "heic", "tiff", "pdf"].contains((lower as NSString).pathExtension)
        return image && (lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot") || lower.hasPrefix("cleanshot"))
    }

    func loadForTesting(_ screenshots: [Screenshot]) {
        items = screenshots.sorted { $0.date > $1.date }
        phase = .ready
    }

    // MARK: Selection

    func toggle(_ item: Screenshot) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func isSelected(_ item: Screenshot) -> Bool { selected.contains(item.id) }
    func selectVisible() { selected.formUnion(visible.map(\.id)) }
    func deselectAll() { selected = [] }

    // MARK: Review

    func startReview(at item: Screenshot? = nil) {
        reviewList = visible
        guard !reviewList.isEmpty else { return }
        reviewIndex = item.flatMap { current in reviewList.firstIndex { $0.id == current.id } } ?? 0
    }

    func keepAndNext() {
        guard let index = reviewIndex, reviewList.indices.contains(index) else { return }
        selected.remove(reviewList[index].id)
        advance()
    }

    func deleteAndNext() {
        guard let index = reviewIndex, reviewList.indices.contains(index) else { return }
        selected.insert(reviewList[index].id)
        advance()
    }

    func back() {
        guard let index = reviewIndex, index > 0 else { return }
        reviewIndex = index - 1
    }

    private func advance() {
        guard let index = reviewIndex else { return }
        reviewIndex = min(index + 1, reviewList.count)
    }

    var isReviewFinished: Bool { (reviewIndex ?? 0) >= reviewList.count }

    func endReview() {
        reviewIndex = nil
        reviewList = []
    }

    // MARK: Deleting

    /// Library: Photos confirms and keeps them in Recently Deleted. Files: to the Trash.
    func deleteSelected(engine: CleanupEngine) async {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        var removed: Set<String> = []
        let libraryIDs = chosen.compactMap { if case .library(let id) = $0.origin { id } else { nil } }
        if !libraryIDs.isEmpty, await PhotoLibrary.delete(libraryIDs) {
            removed.formUnion(chosen.filter { if case .library = $0.origin { true } else { false } }.map(\.id))
        }
        let files = chosen.compactMap { item -> JunkItem? in
            guard let path = item.path else { return nil }
            return JunkItem(path: path, name: (path as NSString).lastPathComponent, detail: nil, size: item.size ?? 0, tier: .review)
        }
        if !files.isEmpty {
            let record = await Task.detached(priority: .userInitiated) { CleanupRemover.remove(files, permanently: false) }.value
            engine.record(record)
            removed.formUnion(record.entries.map { "file:" + $0.originalPath })
        }
        items.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
    }
}

/// Small shared cache of screenshot/photo thumbnails.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    /// Full-size previews are big; keep only a handful (current, previous, next…).
    private let large = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 600
        large.countLimit = 8
    }

    private static func key(_ origin: Screenshot.Origin, _ maxPixel: CGFloat) -> NSString { "\(origin)|\(Int(maxPixel))" as NSString }

    /// Already loaded? (For showing the small version instantly while the big one loads.)
    func cached(_ origin: Screenshot.Origin, maxPixel: CGFloat) -> NSImage? {
        large.object(forKey: Self.key(origin, maxPixel)) ?? cache.object(forKey: Self.key(origin, maxPixel))
    }

    /// Big preview: yields a quick version first, then the full one (downloaded from iCloud if
    /// needed). `final` is true for the last image.
    func preview(for origin: Screenshot.Origin, maxPixel: CGFloat) -> AsyncStream<(image: NSImage, final: Bool)> {
        let key = Self.key(origin, maxPixel)
        if let done = large.object(forKey: key) {
            return AsyncStream { $0.yield((done, true)); $0.finish() }
        }
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                switch origin {
                case .library(let id):
                    for await (cgImage, final) in PhotoLibrary.images(for: id, maxPixel: maxPixel) {
                        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        if final { self.large.setObject(image, forKey: key) }
                        continuation.yield((image, final))
                    }
                case .file(let path):
                    if let cgImage = await Task.detached(priority: .userInitiated, operation: { SimilarPhotos.thumbnail(path: path, maxPixel: Int(maxPixel)) }).value {
                        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        self.large.setObject(image, forKey: key)
                        continuation.yield((image, true))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Warm the next preview so arrowing through is instant.
    func prefetch(_ origin: Screenshot.Origin, maxPixel: CGFloat) {
        guard large.object(forKey: Self.key(origin, maxPixel)) == nil else { return }
        Task { for await _ in preview(for: origin, maxPixel: maxPixel) {} }
    }

    func image(for origin: Screenshot.Origin, maxPixel: CGFloat) async -> NSImage? {
        let key = "\(origin)|\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let cgImage: CGImage? = switch origin {
        case .library(let id): await PhotoLibrary.image(for: id, maxPixel: maxPixel)
        case .file(let path): await Task.detached(priority: .userInitiated) { SimilarPhotos.thumbnail(path: path, maxPixel: Int(maxPixel)) }.value
        }
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }
}
