import Foundation

/// How confident we are that removing something is harmless. Drives default selection:
/// only `.safe` items are pre-selected.
enum SafetyTier: Int, Codable, Comparable, CaseIterable, Sendable {
    /// Rebuilt or re-downloaded automatically. Pre-selected.
    case safe
    /// Probably unneeded, but worth a glance (old installers, idle projects' dependencies).
    case review
    /// Can't be undone or might be wanted (e.g. already in the Trash). Never pre-selected.
    case careful

    static func < (a: SafetyTier, b: SafetyTier) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .careful: "Careful"
        }
    }

    var explanation: String {
        switch self {
        case .safe: "Rebuilt or re-downloaded automatically when needed."
        case .review: "Probably not needed, but take a quick look."
        case .careful: "Can't be undone. Only remove if you're sure."
        }
    }
}

/// The areas Clean Up covers. Each is scanned by its own independent module.
enum CleanupModuleKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemJunk, developerJunk, downloads, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemJunk: "System Junk"
        case .developerJunk: "Developer Junk"
        case .downloads: "Downloads & Installers"
        case .trash: "Trash"
        }
    }

    var subtitle: String {
        switch self {
        case .systemJunk: "Caches and logs apps rebuild on their own."
        case .developerJunk: "Build data, simulators, package caches and old project dependencies."
        case .downloads: "Installers you've already used and big files you've forgotten."
        case .trash: "Files already in the Trash, waiting to be deleted."
        }
    }

    var icon: String {
        switch self {
        case .systemJunk: "archivebox"
        case .developerJunk: "hammer"
        case .downloads: "arrow.down.circle"
        case .trash: "trash"
        }
    }
}

/// One removable thing: a folder or file.
struct JunkItem: Identifiable, Hashable, Codable, Sendable {
    let path: String
    let name: String
    /// Plain-language context ("shop · not touched in 4 months").
    var detail: String?
    let size: Int64
    let tier: SafetyTier

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// A set of similar items with one explanation (e.g. "Xcode build data").
struct JunkGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    /// What this is and why it's there.
    let explanation: String
    /// What happens after you remove it.
    let afterRemoval: String
    let items: [JunkItem]
    /// Removing these deletes them permanently (the Trash itself).
    var isPermanent = false

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct ModuleScan: Identifiable, Sendable {
    let module: CleanupModuleKind
    let groups: [JunkGroup]
    /// macOS privacy settings blocked part of the scan.
    var needsAccess = false

    var id: CleanupModuleKind { module }
    var items: [JunkItem] { groups.flatMap(\.items) }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var safeSize: Int64 { items.filter { $0.tier == .safe }.reduce(0) { $0 + $1.size } }
}
