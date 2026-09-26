import Foundation
import Vision
import CoreGraphics
import ImageIO

/// Near-duplicate photos: bursts, retakes, the same shot edited or re-saved. Uses Apple's
/// on-device image feature prints (Vision), so nothing leaves the Mac, and Apple's aesthetics
/// score to suggest the best shot of each set.
enum SimilarPhotos {
    /// Feature-print distance below which two photos are "the same shot". Calibrated on
    /// Apple's wallpapers: reframed or lightly edited copies measure 0.11–0.39, different
    /// photos of the same subject (four flowers) 0.61–0.64, unrelated photos 0.8+.
    static let threshold: Float = 0.40

    /// Only photos taken close together are compared: similar shots come in bursts, and it
    /// keeps a large library fast (each photo is compared with its neighbors, not everything).
    static let window: TimeInterval = 10 * 60
    static let maxNeighbors = 40

    struct Analysis: Sendable {
        let print: VNFeaturePrintObservation
        /// Apple's aesthetics score, -1…1 (higher is a better photo). nil if unavailable.
        let quality: Float?
        /// Screenshots, receipts, documents: Vision flags these as "utility" images.
        let isUtility: Bool
    }

    static func analyze(_ image: CGImage) -> Analysis? {
        let printRequest = VNGenerateImageFeaturePrintRequest()
        printRequest.imageCropAndScaleOption = .scaleFill
        let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([printRequest, aestheticsRequest])
        } catch {
            return nil
        }
        guard let print = printRequest.results?.first else { return nil }
        let aesthetics = aestheticsRequest.results?.first
        return Analysis(print: print, quality: aesthetics?.overallScore, isUtility: aesthetics?.isUtility ?? false)
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        guard (try? a.computeDistance(&distance, to: b)) != nil else { return nil }
        return distance
    }

    /// Groups items (sorted by date) whose prints are within `threshold` of a neighbor taken
    /// within `window`. Returns index sets of 2+ items.
    static func cluster(dates: [Date], prints: [VNFeaturePrintObservation?], threshold: Float = threshold,
                        window: TimeInterval = window, maxNeighbors: Int = maxNeighbors) -> [[Int]] {
        var parent = Array(0..<dates.count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in dates.indices {
            guard let a = prints[i] else { continue }
            var j = i + 1
            while j < dates.count, j - i <= maxNeighbors, dates[j].timeIntervalSince(dates[i]) <= window {
                if let b = prints[j], let d = distance(a, b), d <= threshold {
                    let (ri, rj) = (root(i), root(j))
                    if ri != rj { parent[rj] = ri }
                }
                j += 1
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in dates.indices where prints[i] != nil { groups[root(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted() }
    }

    /// Small version of an image file for analysis (uses the embedded thumbnail when there is one).
    static func thumbnail(path: String, maxPixel: Int = 512) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// When the photo was taken (EXIF), falling back to nil.
    static func captureDate(path: String) -> Date? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: original)
    }

    static func pixelSize(path: String) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
