import Foundation
import Observation
import UniformTypeIdentifiers
import Vision

/// Sets of near-identical photos (bursts, retakes) from the Photos library or folders, with
/// the best shot of each suggested by Apple's aesthetics score.
@MainActor
@Observable
final class SimilarPhotosModel {
    enum Source: String { case library, folders }
    enum Phase: Equatable { case idle, analyzing, ready }

    struct Photo: Identifiable, Hashable, Sendable {
        let origin: Screenshot.Origin
        let date: Date
        let pixels: Int
        var quality: Float?
        var size: Int64?
        var isFavorite = false

        var id: String {
            switch origin {
            case .library(let id): "library:" + id
            case .file(let path): "file:" + path
            }
        }
    }

    struct Group: Identifiable, Sendable {
        let photos: [Photo]
        var id: String { photos.first?.id ?? "" }
        /// Best shot: favorites first, then Apple's aesthetics score, then resolution.
        var best: Photo? { photos.max { SimilarPhotosModel.rank($0).lexicographicallyPrecedes(SimilarPhotosModel.rank($1)) } }
        var span: TimeInterval { (photos.map(\.date).max() ?? .now).timeIntervalSince(photos.map(\.date).min() ?? .now) }
    }

    nonisolated static func rank(_ photo: Photo) -> [Double] {
        [photo.isFavorite ? 1 : 0, Double(photo.quality ?? -2), Double(photo.pixels)]
    }

    var source: Source {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "similar.source")
            groups = []
            selected = []
            phase = .idle
        }
    }
    /// Library: only the last year by default (fast); "All" goes through everything.
    var wholeLibrary = false
    private(set) var phase: Phase = .idle
    private(set) var analyzed = 0
    private(set) var total = 0
    private(set) var groups: [Group] = []
    private(set) var selected: Set<String> = []
    @ObservationIgnored private var cancelled = false

    init() {
        source = Source(rawValue: UserDefaults.standard.string(forKey: "similar.source") ?? "") ?? .library
    }

    var selectedPhotos: [Photo] { groups.flatMap(\.photos).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedPhotos.reduce(0) { $0 + ($1.size ?? 0) } }
    var extraPhotos: Int { groups.reduce(0) { $0 + $1.photos.count - 1 } }

    func isSelected(_ photo: Photo) -> Bool { selected.contains(photo.id) }

    func canSelect(_ photo: Photo, in group: Group) -> Bool {
        isSelected(photo) || group.photos.filter { !isSelected($0) }.count > 1
    }

    func toggle(_ photo: Photo, in group: Group) {
        if selected.contains(photo.id) { selected.remove(photo.id) } else if canSelect(photo, in: group) { selected.insert(photo.id) }
    }

    /// Everything but the best shot, except favorites, which are never picked for you.
    func autoSelect() {
        var picks: Set<String> = []
        for group in groups {
            guard let best = group.best else { continue }
            for photo in group.photos where photo.id != best.id && !photo.isFavorite { picks.insert(photo.id) }
        }
        selected = picks
    }

    func deselectAll() { selected = [] }

    // MARK: Analysis

    func scan(folders: [String]) async {
        cancel()
        cancelled = false
        phase = .analyzing
        analyzed = 0
        groups = []
        selected = []

        let candidates: [Photo]
        switch source {
        case .library:
            let since = wholeLibrary ? nil : Calendar.current.date(byAdding: .year, value: -1, to: Date())
            let assets = await Task.detached(priority: .userInitiated) { PhotoLibrary.photos(since: since) }.value
            candidates = assets.map { Photo(origin: .library($0.id), date: $0.date, pixels: $0.pixelWidth * $0.pixelHeight, isFavorite: $0.isFavorite) }
        case .folders:
            candidates = await Task.detached(priority: .userInitiated) { Self.photoFiles(in: folders) }.value
        }
        total = candidates.count

        // Analyze a few at a time (Vision runs on the Neural Engine; images load in parallel).
        var prints = [VNFeaturePrintObservation?](repeating: nil, count: candidates.count)
        var photos = candidates
        await withTaskGroup(of: (Int, SimilarPhotos.Analysis?).self) { group in
            var next = 0
            func enqueue() {
                guard next < candidates.count else { return }
                let index = next, origin = candidates[index].origin
                next += 1
                group.addTask {
                    let image: CGImage? = switch origin {
                    case .library(let id): await PhotoLibrary.analysisImage(for: id)
                    case .file(let path): SimilarPhotos.thumbnail(path: path, maxPixel: 512)
                    }
                    return (index, image.flatMap(SimilarPhotos.analyze))
                }
            }
            for _ in 0..<6 { enqueue() }
            for await (index, analysis) in group {
                if let analysis, !analysis.isUtility { // receipts, documents and the like aren't "photos"
                    prints[index] = analysis.print
                    photos[index].quality = analysis.quality
                }
                analyzed += 1
                if cancelled { group.cancelAll(); return }
                enqueue()
            }
        }
        guard phase == .analyzing else { return }
        let clusters = SimilarPhotos.cluster(dates: photos.map(\.date), prints: prints)
        var found = clusters.map { Group(photos: $0.map { photos[$0] }) }
        // Sizes only for photos in sets (fetching them for a whole library is slow).
        if source == .library {
            let ids = found.flatMap(\.photos).compactMap { if case .library(let id) = $0.origin { id } else { nil } }
            let sizes = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: PhotoLibrary.fetch(ids).map { ($0.localIdentifier, PhotoLibrary.fileSize($0)) })
            }.value
            found = found.map { group in
                Group(photos: group.photos.map { photo in
                    var photo = photo
                    if case .library(let id) = photo.origin { photo.size = sizes[id] ?? nil }
                    return photo
                })
            }
        }
        groups = found.sorted { $0.photos.count > $1.photos.count }
        autoSelect()
        phase = .ready
    }

    func cancel() {
        cancelled = true
        if phase == .analyzing { phase = groups.isEmpty ? .idle : .ready }
    }

    /// Image files in the folders (not screenshots, not inside packages or hidden folders).
    nonisolated static func photoFiles(in folders: [String]) -> [Photo] {
        let fm = FileManager.default
        var photos: [Photo] = []
        for folder in folders {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: folder),
                                                 includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if DuplicateScanner.skippedFolderNames.contains(name) { enumerator.skipDescendants(); continue }
                guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
                      !type.conforms(to: .pdf), !ScreenshotsModel.isScreenshotName(name) else { continue }
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                guard let size = values?.fileSize, size >= 50_000 else { continue }
                let pixels = SimilarPhotos.pixelSize(path: url.path).map { $0.0 * $0.1 } ?? 0
                photos.append(Photo(origin: .file(url.path), date: SimilarPhotos.captureDate(path: url.path) ?? values?.creationDate ?? .distantPast,
                                    pixels: pixels, size: Int64(size)))
            }
        }
        return photos.sorted { $0.date < $1.date }
    }

    // MARK: Deleting

    func deleteSelected(engine: CleanupEngine) async {
        let chosen = selectedPhotos
        var removed: Set<String> = []
        let libraryIDs = chosen.compactMap { if case .library(let id) = $0.origin { id } else { nil } }
        if !libraryIDs.isEmpty, await PhotoLibrary.delete(libraryIDs) {
            removed.formUnion(libraryIDs.map { "library:" + $0 })
        }
        let files = chosen.compactMap { photo -> JunkItem? in
            guard case .file(let path) = photo.origin else { return nil }
            return JunkItem(path: path, name: (path as NSString).lastPathComponent, detail: nil, size: photo.size ?? 0, tier: .review)
        }
        if !files.isEmpty {
            let record = await Task.detached(priority: .userInitiated) { CleanupRemover.remove(files, permanently: false) }.value
            engine.record(record)
            removed.formUnion(record.entries.map { "file:" + $0.originalPath })
        }
        groups = groups.compactMap { group in
            let left = group.photos.filter { !removed.contains($0.id) }
            return left.count > 1 ? Group(photos: left) : nil
        }
        selected.subtract(removed)
    }
}
