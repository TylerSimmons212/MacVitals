import Foundation

/// Shared display formatting. Memory uses binary units (like Activity Monitor);
/// disk and network use decimal units (like Finder).
enum Fmt {
    private static let memoryFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let fileFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func memory(_ bytes: UInt64) -> String {
        memoryFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// Just the number in binary gigabytes ("12.4"), for layouts that show the unit separately.
    static func gigabytesNumber(_ bytes: UInt64, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", Double(bytes) / Double(1 << 30))
    }

    /// Decimal (Finder-style) number and unit separately: ("182", "GB"), ("1.2", "TB").
    static func splitBytes(_ bytes: Int64) -> (number: String, unit: String) {
        let value = Double(max(0, bytes))
        if value >= 1e12 { return (String(format: "%.1f", value / 1e12), "TB") }
        if value >= 1e11 { return (String(format: "%.0f", value / 1e9), "GB") }
        if value >= 1e9 { return (String(format: "%.1f", value / 1e9), "GB") }
        return (String(format: "%.0f", value / 1e6), "MB")
    }

    static func bytes(_ bytes: Int64) -> String {
        fileFormatter.string(fromByteCount: max(0, bytes))
    }

    static func bytes(_ bytes: UInt64) -> String {
        fileFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "0 KB/s" }
        return fileFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func percent(_ value: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", value.isFinite ? value : 0)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? "—"
    }
}
