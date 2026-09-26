import Foundation
import Photos
import AppKit

/// The Photos library, read through PhotoKit (never by touching the library's files, which
/// would corrupt it). Deleting goes through Photos too: it shows its own confirmation, and
/// deleted items wait in Recently Deleted for 30 days.
enum PhotoLibrary {
    struct Asset: Identifiable, Hashable, Sendable {
        let id: String
        let date: Date
        let pixelWidth: Int
        let pixelHeight: Int
        var size: Int64?
        let isFavorite: Bool
        let isScreenshot: Bool
    }

    static var isAvailable: Bool { Permissions.photosStatus() == .granted }

    /// Screenshots, newest first.
    static func screenshots() -> [Asset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return assets(PHAsset.fetchAssets(with: .image, options: options), withSizes: true)
    }

    /// Photos (not screenshots), oldest first, optionally since a date.
    static func photos(since: Date?) -> [Asset] {
        let options = PHFetchOptions()
        var predicates = [NSPredicate(format: "(mediaSubtypes & %d) == 0", PHAssetMediaSubtype.photoScreenshot.rawValue)]
        if let since { predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return assets(PHAsset.fetchAssets(with: .image, options: options), withSizes: false)
    }

    private static func assets(_ result: PHFetchResult<PHAsset>, withSizes: Bool) -> [Asset] {
        var assets: [Asset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(Asset(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast,
                                pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                size: withSizes ? fileSize(asset) : nil, isFavorite: asset.isFavorite,
                                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
        }
        return assets
    }

    /// Size of the original, when Photos knows it (it may live only in iCloud).
    static func fileSize(_ asset: PHAsset) -> Int64? {
        guard let resource = PHAssetResource.assetResources(for: asset).first,
              resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    static func fetch(_ ids: [String]) -> [PHAsset] {
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// A local image for display or analysis. Never downloads from iCloud (uses what's on this Mac).
    static func image(for id: String, maxPixel: CGFloat) async -> CGImage? {
        guard let asset = fetch([id]).first else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        let target = CGSize(width: maxPixel, height: maxPixel)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    /// Photos shows its own "Delete N items?" confirmation; items go to Recently Deleted.
    static func delete(_ ids: [String]) async -> Bool {
        let assets = fetch(ids)
        guard !assets.isEmpty else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            return true
        } catch {
            return false // cancelled in Photos' confirmation, or not allowed
        }
    }

    static func openPhotos() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        }
    }
}
