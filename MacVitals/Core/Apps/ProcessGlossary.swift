import Foundation

/// Plain explanations for processes people often don't recognize, so nobody panics at
/// "mds_stores" or quits something important. Matched by process name (prefix match).
enum ProcessGlossary {
    struct Entry: Sendable {
        let what: String
        /// Should people worry if it's busy? nil = no specific advice.
        let busyAdvice: String?
    }

    static func explain(_ processName: String) -> Entry? {
        if let exact = entries[processName] { return exact }
        return prefixed.first { processName.hasPrefix($0.prefix) }?.entry
    }

    private static let entries: [String: Entry] = [
        "WindowServer": Entry(what: "Draws everything on your screen.", busyAdvice: "Busier with many windows, external displays or animations. Normal."),
        "kernel_task": Entry(what: "The core of macOS.", busyAdvice: "High CPU here often means macOS is cooling the Mac down on purpose."),
        "launchd": Entry(what: "Starts and manages every other process.", busyAdvice: nil),
        "loginwindow": Entry(what: "Manages your login session.", busyAdvice: nil),
        "mds": Entry(what: "Spotlight, the search index for your files.", busyAdvice: "Busy after updates or when lots of files change. Finishes on its own."),
        "mds_stores": Entry(what: "Spotlight saving its search index.", busyAdvice: "Busy after updates or big file changes. Temporary."),
        "mdworker": Entry(what: "Spotlight reading files to index them.", busyAdvice: "Temporary while indexing."),
        "mdworker_shared": Entry(what: "Spotlight reading files to index them.", busyAdvice: "Temporary while indexing."),
        "corespotlightd": Entry(what: "Spotlight indexing app content (mail, messages, notes).", busyAdvice: "Temporary."),
        "photoanalysisd": Entry(what: "Photos recognizing faces, places and objects.", busyAdvice: "Runs mostly when your Mac is idle and plugged in. Finishes eventually."),
        "photolibraryd": Entry(what: "Manages your Photos library.", busyAdvice: "Busy while importing or syncing iCloud Photos."),
        "mediaanalysisd": Entry(what: "Analyzes photos and videos for search and Memories.", busyAdvice: "Temporary; happens after importing lots of media."),
        "cloudd": Entry(what: "iCloud syncing.", busyAdvice: "Busy while uploading or downloading iCloud files."),
        "bird": Entry(what: "iCloud Drive syncing.", busyAdvice: "Busy while syncing iCloud Drive."),
        "fileproviderd": Entry(what: "Keeps cloud files (iCloud, Dropbox, Google Drive) in sync with Finder.", busyAdvice: "Busy while syncing."),
        "backupd": Entry(what: "Time Machine backing up.", busyAdvice: "Busy during backups. Normal."),
        "softwareupdated": Entry(what: "Checks for and downloads macOS updates.", busyAdvice: "Busy while downloading or preparing an update."),
        "trustd": Entry(what: "Checks security certificates for websites and apps.", busyAdvice: nil),
        "coreaudiod": Entry(what: "Handles all sound in and out of your Mac.", busyAdvice: "Busier while playing audio or on calls."),
        "bluetoothd": Entry(what: "Manages Bluetooth devices.", busyAdvice: nil),
        "airportd": Entry(what: "Manages Wi-Fi.", busyAdvice: nil),
        "nsurlsessiond": Entry(what: "Background downloads for apps and macOS.", busyAdvice: "Busy while something downloads in the background."),
        "apsd": Entry(what: "Apple push notifications.", busyAdvice: nil),
        "rapportd": Entry(what: "Lets your Apple devices find each other (Handoff, AirDrop).", busyAdvice: nil),
        "sharingd": Entry(what: "AirDrop, Handoff and sharing.", busyAdvice: nil),
        "Finder": Entry(what: "Your file browser and desktop.", busyAdvice: "Busy while copying files or showing big folders."),
        "Dock": Entry(what: "The Dock, Launchpad and Mission Control.", busyAdvice: nil),
        "SystemUIServer": Entry(what: "Parts of the menu bar.", busyAdvice: nil),
        "ControlCenter": Entry(what: "Control Center and menu bar status items.", busyAdvice: nil),
        "NotificationCenter": Entry(what: "Notifications and widgets.", busyAdvice: nil),
        "WindowManager": Entry(what: "Stage Manager and window layouts.", busyAdvice: nil),
        "Spotlight": Entry(what: "The Spotlight search window.", busyAdvice: nil),
        "suggestd": Entry(what: "Siri Suggestions learning from your apps.", busyAdvice: "Occasionally busy. Temporary."),
        "knowledge-agent": Entry(what: "Learns your usage patterns for suggestions.", busyAdvice: "Temporary."),
        "triald": Entry(what: "Apple's background feature experiments.", busyAdvice: nil),
        "ReportCrash": Entry(what: "Writes a crash report after an app crashes.", busyAdvice: "Briefly busy after a crash."),
        "XprotectService": Entry(what: "Built-in malware protection.", busyAdvice: "Briefly busy when scanning new apps or downloads."),
        "syspolicyd": Entry(what: "Checks that apps are safe to open (Gatekeeper).", busyAdvice: "Briefly busy when opening new apps."),
        "SourceKitService": Entry(what: "Xcode's code completion and syntax engine.", busyAdvice: "Busy while editing Swift. Normal."),
        "swift-frontend": Entry(what: "The Swift compiler (building code).", busyAdvice: "Busy while building. Normal."),
        "clang": Entry(what: "The C/Objective-C compiler (building code).", busyAdvice: "Busy while building. Normal."),
        "XCBBuildService": Entry(what: "Xcode's build system.", busyAdvice: "Busy while building."),
        "node": Entry(what: "JavaScript runtime: dev servers, build tools, or Electron apps.", busyAdvice: "Check Dev Servers for any you forgot to stop."),
        "python3": Entry(what: "A Python program or script.", busyAdvice: nil),
        "java": Entry(what: "A Java program (IDEs, build tools, Minecraft…).", busyAdvice: nil),
        "com.docker.backend": Entry(what: "Docker's engine.", busyAdvice: "Uses memory while Docker Desktop runs, even when idle."),
    ]

    private static let prefixed: [(prefix: String, entry: Entry)] = [
        ("com.apple.WebKit.WebContent", Entry(what: "A web page open in Safari (or another app using WebKit).", busyAdvice: "A busy one is usually a heavy page or video. Close the tab.")),
        ("com.apple.WebKit.GPU", Entry(what: "Graphics for web pages.", busyAdvice: nil)),
        ("com.apple.WebKit.Networking", Entry(what: "Network requests for web pages.", busyAdvice: nil)),
        ("Google Chrome Helper (Renderer)", Entry(what: "A Chrome tab or extension.", busyAdvice: "Chrome's Task Manager (Window › Task Manager) shows which tab.")),
        ("Google Chrome Helper (GPU)", Entry(what: "Chrome's graphics.", busyAdvice: nil)),
        ("Google Chrome Helper", Entry(what: "Part of Chrome.", busyAdvice: nil)),
        ("Microsoft Edge Helper", Entry(what: "Part of Edge (tabs and extensions).", busyAdvice: nil)),
        ("Code Helper", Entry(what: "Part of VS Code (extensions, language servers, terminals).", busyAdvice: nil)),
        ("Slack Helper", Entry(what: "Part of Slack.", busyAdvice: nil)),
        ("MTLCompilerService", Entry(what: "Prepares graphics for games and apps.", busyAdvice: "Briefly busy the first time an app or game runs.")),
        ("VTDecoderXPCService", Entry(what: "Decodes video playback.", busyAdvice: "Busy while playing video.")),
        ("VTEncoderXPCService", Entry(what: "Encodes video (screen recording, calls, exports).", busyAdvice: "Busy while recording or exporting video.")),
        ("mdworker", Entry(what: "Spotlight reading files to index them.", busyAdvice: "Temporary while indexing.")),
    ]
}
