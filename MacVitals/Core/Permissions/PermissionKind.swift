import Foundation

/// Every macOS permission Mac Vitals can use. All optional: the app works without any of them,
/// and each one is explained by what it unlocks, in plain words.
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case fullDiskAccess
    case location
    case appManagement
    case finder
    case photos
    case notifications

    var id: String { rawValue }

    /// What it's called in System Settings, so people can find it.
    var systemName: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .location: "Location Services"
        case .appManagement: "App Management"
        case .finder: "Automation › Finder"
        case .photos: "Photos"
        case .notifications: "Notifications"
        }
    }

    /// The benefit, not the mechanism.
    var benefit: String {
        switch self {
        case .fullDiskAccess: "See everything that takes up space"
        case .location: "Show your Wi-Fi network's name"
        case .appManagement: "Uninstall apps"
        case .finder: "Remove items installed for all users"
        case .photos: "Clean up screenshots and similar photos"
        case .notifications: "Tell you when something needs attention"
        }
    }

    var explanation: String {
        switch self {
        case .fullDiskAccess:
            "macOS locks the Trash, Mail and Messages, iPhone backups and data other apps keep private. With access, Storage and Clean Up can see and measure all of it."
        case .location:
            "macOS counts Wi-Fi network names as location data. Mac Vitals only shows the name on the Network page and never looks up where you are."
        case .appManagement:
            "macOS asks before one app deletes another. This lets the Uninstaller move apps to the Trash."
        case .notifications:
            "A heads-up when your disk is nearly full, an app is stuck, or a protection gets switched off, even with the window closed. Only things worth interrupting you for; choose which in Settings."
        case .photos:
            "Lets Mac Vitals find screenshots and near-identical shots in your Photos library. Photos asks you to confirm anything deleted, and it goes to Recently Deleted for 30 days."
        case .finder:
            "Some apps and helpers are installed for every user. Mac Vitals asks Finder to move them to the Trash. Finder asks for your password, and they stay in the Trash until you empty it."
        }
    }

    /// What it unlocks, feature by feature.
    var unlocks: [String] {
        switch self {
        case .fullDiskAccess: ["Trash size and emptying", "Mail and Messages attachments", "iPhone and iPad backups", "Complete app leftovers"]
        case .location: ["Network page: which Wi-Fi you're on"]
        case .appManagement: ["Uninstaller: moving apps to the Trash"]
        case .finder: ["Uninstaller and Startup Items: protected apps and helpers"]
        case .photos: ["Screenshots in your library", "Similar photos in your library"]
        case .notifications: ["Alerts for disk, memory, heat, stuck apps, protections and updates"]
        }
    }

    var privacyNote: String {
        switch self {
        case .fullDiskAccess: "Only sizes and names are read, never file contents. Nothing leaves your Mac."
        case .location: "Your location is never requested or stored."
        case .appManagement: "Only apps you choose to uninstall are touched."
        case .finder: "Finder is only asked to move items you choose."
        case .photos: "Photos are analyzed on this Mac and never leave it."
        case .notifications: "Never more than a few an hour, and never while you're looking at Mac Vitals."
        }
    }

    var icon: String {
        switch self {
        case .fullDiskAccess: "externaldrive.fill.badge.checkmark"
        case .location: "wifi"
        case .appManagement: "square.grid.3x3.fill"
        case .finder: "folder.fill.badge.person.crop"
        case .photos: "photo.on.rectangle.angled"
        case .notifications: "bell.badge.fill"
        }
    }

    var isRecommended: Bool { self == .fullDiskAccess }

    /// How macOS grants it: a list you add the app to, or a one-tap system prompt.
    enum GrantStyle { case settingsList, systemPrompt }

    var grantStyle: GrantStyle {
        switch self {
        case .fullDiskAccess, .appManagement: .settingsList
        case .location, .finder, .photos, .notifications: .systemPrompt
        }
    }

    /// Deep link to the exact pane in System Settings › Privacy & Security.
    var settingsURL: URL {
        if self == .notifications {
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
        }
        let anchor = switch self {
        case .fullDiskAccess: "Privacy_AllFiles"
        case .location: "Privacy_LocationServices"
        case .appManagement: "Privacy_AppBundles"
        case .finder: "Privacy_Automation"
        case .photos: "Privacy_Photos"
        case .notifications: ""
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

}

enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    /// macOS gives no way to check until it's needed.
    case unknown

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Off"
        case .notDetermined: "Not allowed yet"
        case .unknown: "Asked when needed"
        }
    }
}
