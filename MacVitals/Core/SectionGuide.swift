import Foundation

/// Plain-language explainer shown from the ⓘ button on each page.
/// Written for people who don't know the jargon, with a glossary for the terms the page uses.
struct SectionGuide: Sendable {
    struct Term: Identifiable, Sendable {
        let term: String
        let meaning: String
        var id: String { term }
    }

    let title: String
    let summary: String
    let healthy: [String]
    let culprits: [String]
    let fixes: [String]
    let glossary: [Term]

    static func `for`(_ section: DashboardSection) -> SectionGuide {
        switch section {
        case .overview: overview
        case .cpu: cpu
        case .memory: memory
        case .disk: disk
        case .network: network
        case .battery: battery
        case .apps: apps
        case .ports: ports
        case .cleanup: cleanup
        case .junk: junk
        case .spaceLens: spaceLens
        case .duplicates: duplicates
        case .screenshots: screenshots
        case .maintenance: maintenance
        case .uninstaller: uninstaller
        case .startup: startup
        case .protection: protection
        case .updates: updates
        }
    }

    static let cpu = SectionGuide(
        title: "Understanding CPU",
        summary: "The CPU (processor) is your Mac's brain. Every app, click and background task asks it to do work. This page shows how much of its capacity is in use and who's asking for it.",
        healthy: [
            "Most of the time it sits low, often under 20%, while you browse, write or watch video.",
            "Short spikes to 100% are normal: opening apps, exporting video, installing updates.",
            "It's only a problem when it stays high for minutes while you're not doing anything demanding.",
            "Seeing Mac Vitals near the top while this window is open is normal. Keeping the numbers live costs a little CPU, and it drops to almost nothing when you close the window.",
        ],
        culprits: [
            "Browser tabs running video, ads or heavy web apps.",
            "Spotlight or Photos indexing after an update or import. Usually finishes on its own.",
            "Backups, sync (iCloud, Dropbox) and antivirus scans.",
            "An app that's stuck in a loop. It shows up at the top of the list and doesn't come down.",
            "Developer tools: compilers, simulators and local servers.",
        ],
        fixes: [
            "Check \"What's using the CPU\" below and quit anything you're not using.",
            "If a single app is stuck high, quit and reopen it.",
            "Give indexing and backups time to finish, ideally while plugged in.",
            "If it's hot and slow, make sure vents aren't blocked; macOS slows the CPU down to cool it.",
            "Still high after all that? A restart clears most stuck processes.",
        ],
        glossary: [
            Term(term: "Apps (User)", meaning: "Work done on behalf of your apps."),
            Term(term: "macOS (System)", meaning: "Work done by macOS itself: drivers, file system, networking."),
            Term(term: "Demand (Load average)", meaning: "How many tasks are running or waiting, averaged over 1, 5 and 15 minutes. Above your core count means work is queuing up."),
            Term(term: "Performance cores", meaning: "Fast cores for demanding work. They use more power."),
            Term(term: "Efficiency cores", meaning: "Low-power cores for background tasks. They keep the battery going."),
            Term(term: "Throttling", meaning: "macOS deliberately slowing the CPU to reduce heat."),
            Term(term: "cores (in the app list)", meaning: "How many cores' worth of work an app is using. 1.0 means one core fully busy."),
        ]
    )

    static let memory = SectionGuide(
        title: "Understanding Memory",
        summary: "Memory (RAM) is your Mac's short-term workspace. Open apps, tabs and documents live here so they're instantly available.",
        healthy: [
            "A high \"used\" number is normal. macOS deliberately fills spare memory with cached files to speed things up.",
            "What matters is memory pressure. Green means everything fits comfortably.",
            "A little swap is fine. Lots of swap, or growing swap, means you're short on RAM.",
        ],
        culprits: [
            "Browsers with dozens of tabs.",
            "Creative apps working on large files (video, photos, 3D).",
            "Virtual machines, Docker and simulators.",
            "An app with a memory leak: it keeps growing the longer it runs.",
        ],
        fixes: [
            "Use \"Free up memory\": it lists heavy apps you haven't used in a while.",
            "Close tabs and apps you aren't using, starting with the biggest.",
            "Quit and reopen an app that keeps growing.",
            "Restart your Mac if it's been up for weeks.",
            "\"Is your RAM enough?\" tells you, from weeks of your own usage, whether your next Mac needs more.",
        ],
        glossary: [
            Term(term: "Pressure (Memory pressure)", meaning: "How hard macOS is working to make everything fit. The best single health signal."),
            Term(term: "In use (Used)", meaning: "Apps + System + Compressed. Usually high on a healthy Mac."),
            Term(term: "Apps (App memory)", meaning: "Memory used by the apps you have open."),
            Term(term: "System (Wired)", meaning: "Memory macOS has locked for itself; it can't be freed."),
            Term(term: "Compressed", meaning: "Memory squeezed to make room. Some is normal; lots means you're tight on RAM."),
            Term(term: "Ready to reuse (Cached files)", meaning: "Recently used files kept in RAM for speed. Freed instantly when apps need it."),
            Term(term: "Overflow to disk (Swap)", meaning: "Memory moved onto the SSD when RAM runs out. Much slower than RAM, and heavy use wears the SSD."),
            Term(term: "Swap activity / Page-outs", meaning: "Memory actively moving to and from the disk. Sustained activity means your Mac is short on RAM (\"thrashing\")."),
            Term(term: "Compression ratio", meaning: "How much macOS is squeezing idle memory. 3× means 3 GB of data stored in 1 GB of RAM."),
        ]
    )

    static let disk = SectionGuide(
        title: "Understanding Disk",
        summary: "Your startup disk (SSD) stores everything: macOS, apps and files. It also acts as overflow memory (swap) and holds temporary files.",
        healthy: [
            "Keep at least 15% free. macOS needs room for updates, swap and caches.",
            "Major macOS updates need roughly 25 GB free to install.",
            "Brief bursts of reading and writing are normal.",
            "Free space that slowly shrinks over days is worth a look. Something is piling up.",
        ],
        culprits: [
            "Caches, logs and old installers building up.",
            "Xcode and simulator data, which can take tens of gigabytes.",
            "iPhone backups and large media libraries.",
            "Heavy swap writes when memory is short.",
        ],
        fixes: [
            "Run Cleanup to reclaim caches, logs and developer junk safely.",
            "Delete or move large files you no longer need.",
            "Check System Settings › General › Storage for recommendations.",
        ],
        glossary: [
            Term(term: "Free (Available)", meaning: "Space for new files, including purgeable space macOS clears on its own when needed."),
            Term(term: "Purgeable", meaning: "Caches and local snapshots macOS can delete automatically. Counts as free."),
            Term(term: "Reading / Writing", meaning: "How fast data is being loaded from or saved to the disk."),
            Term(term: "Swap", meaning: "When memory runs out, macOS writes memory to disk. Shows up here as heavy writing."),
        ]
    )

    static let network = SectionGuide(
        title: "Understanding Network",
        summary: "Whether your connection is healthy, and if not, whether the problem is your Wi-Fi or your internet provider. Plus what's using your data.",
        healthy: [
            "Response time under 50 ms feels instant; under 100 ms is fine for almost everything.",
            "Your router should answer in a few milliseconds. If it's slow, the problem is Wi-Fi, not your internet.",
            "Steady uploads while idle usually mean a backup or cloud sync is running.",
        ],
        culprits: [
            "Weak Wi-Fi: distance, walls, or interference from other networks and microwaves.",
            "A busy connection: someone streaming or a big download on the same network.",
            "Cloud sync (iCloud, Dropbox, Google Drive) and backups.",
            "VPNs add delay because traffic takes a detour.",
        ],
        fixes: [
            "Weak Wi-Fi? Move closer to the router, or use 5 GHz / 6 GHz if you can.",
            "Slow internet with good Wi-Fi? Restart the router, or check with your provider.",
            "Pause sync apps if they're saturating a slow connection.",
            "Run the speed test to see what your connection can handle.",
        ],
        glossary: [
            Term(term: "Response time (Ping)", meaning: "How long a tiny message takes to come back. Measured to your router and to the internet (1.1.1.1)."),
            Term(term: "Wi-Fi signal (RSSI)", meaning: "Signal strength in dBm. −50 is excellent, −70 is okay, below −75 is weak."),
            Term(term: "Signal-to-noise", meaning: "How far your signal stands above background interference. 25 dB or more is clean."),
            Term(term: "Link rate", meaning: "The speed your Mac and router agreed on. Your internet can't be faster than this over Wi-Fi."),
            Term(term: "Responsiveness (RPM)", meaning: "Apple's measure of how well a connection copes when busy. High is great for calls and games."),
            Term(term: "Packet loss", meaning: "Messages that never came back. Any loss makes calls and games stutter."),
        ]
    )

    static let battery = SectionGuide(
        title: "Understanding Battery",
        summary: "How healthy your battery is, what it's doing right now, what's draining it, and how long a charge lasts for the way you use your Mac.",
        healthy: [
            "80% or more of the original capacity is normal. Apple recommends service below that.",
            "Most Mac batteries are rated for about 1,000 charge cycles.",
            "\"Paused near 80%\" while plugged in is Optimized Battery Charging protecting the battery. Nothing is wrong.",
        ],
        culprits: [
            "Apps working hard (video calls, games, compiling, lots of browser tabs).",
            "A bright screen and external displays.",
            "Heat. It drains the battery now and ages it over time.",
        ],
        fixes: [
            "Check \"What's using your battery\" and quit what you don't need.",
            "Use Low Power Mode when you need to stretch a charge.",
            "Keep Optimized Battery Charging on in System Settings › Battery.",
        ],
        glossary: [
            Term(term: "Health (Maximum capacity)", meaning: "How much charge it holds compared with new. Same number as System Settings."),
            Term(term: "Charge cycle", meaning: "Using 100% of the battery's charge, even spread over several days."),
            Term(term: "Power use (W)", meaning: "How fast energy is leaving the battery. Lower lasts longer."),
            Term(term: "Impact", meaning: "Each app's share of power, measured by macOS's own per-app energy accounting."),
            Term(term: "mAh / Voltage / Current", meaning: "The battery's electrical readings: capacity, pack voltage and current flow."),
        ]
    )

    static let overview = SectionGuide(
        title: "Understanding the Health Score",
        summary: "One number from 0 to 100 that sums up how your Mac is doing right now, based on storage, memory, CPU, temperature, battery and uptime.",
        healthy: [
            "90+ is excellent. 75–89 is good.",
            "Anything that lowers the score appears as a vital sign with a warning.",
        ],
        culprits: [
            "A nearly full disk has the biggest impact.",
            "Memory pressure, sustained CPU load and overheating come next.",
        ],
        fixes: [
            "Click any vital sign to see details and what to do.",
        ],
        glossary: []
    )

    static let apps = SectionGuide(
        title: "Understanding Apps",
        summary: "Everything running on your Mac: the apps you opened, things running in the background, and parts of macOS. Each app's helper processes are grouped together so you see its true cost.",
        healthy: [
            "Apps you aren't using should sit at Low impact.",
            "A busy app is normal while it's working (exporting, syncing, compiling). It should calm down afterwards.",
            "macOS processes are usually safe to ignore. Hover over one to see what it does.",
        ],
        culprits: [
            "An app stuck busy for many minutes, often a frozen web page or a bug.",
            "Memory that keeps growing and never shrinks (a leak), common in long-running apps and browser tabs.",
            "Background apps you forgot were installed: updaters, sync tools, launchers.",
        ],
        fixes: [
            "Check \"Needs attention\" at the top. It flags apps that are stuck or leaking, with a Quit button.",
            "Quit asks the app to close normally so it can save. Use Force Quit only if it won't respond.",
            "Expand an app to see its individual processes (for example, one per browser tab).",
        ],
        glossary: [
            Term(term: "Impact", meaning: "One rating combining CPU, memory and energy. High means it's noticeably affecting your Mac."),
            Term(term: "Process", meaning: "A single running program. One app can run many."),
            Term(term: "Background", meaning: "Programs without a Dock icon: menu bar apps, helpers, updaters and services."),
            Term(term: "% CPU (Detailed view)", meaning: "Share of one core, like Activity Monitor. 100% means one core fully busy."),
            Term(term: "Energy (W)", meaning: "Power the app is drawing, from macOS's own per-app energy accounting."),
        ]
    )

    static let ports = SectionGuide(
        title: "Understanding Dev Servers",
        summary: "Programs on your Mac that accept network connections. For developers: local servers grouped by project. For everyone: which parts of macOS and your apps are listening, and why.",
        healthy: [
            "Servers for the project you're working on right now.",
            "Dev servers that say \"only this Mac\" (bound to 127.0.0.1) are private.",
            "macOS services like AirPlay Receiver and Continuity are normal.",
        ],
        culprits: [
            "Servers left running from earlier projects, quietly holding memory and ports.",
            "Servers bound to 0.0.0.0 are reachable by anyone on the same Wi-Fi, which is risky in cafés and airports.",
            "\"Address already in use\" errors: something is still holding the port.",
        ],
        fixes: [
            "Use \"Stop all idle\" to clear forgotten servers.",
            "Type a port into \"What's using a port?\" to find and stop whatever holds it.",
            "Start dev servers with --host 127.0.0.1 (or localhost) to keep them private.",
            "Turn off sharing services you don't use in System Settings › General › Sharing.",
        ],
        glossary: [
            Term(term: "Port", meaning: "A numbered door a server listens on, like :3000."),
            Term(term: "Idle", meaning: "Running for 30+ minutes and not doing anything right now."),
            Term(term: "On your network (0.0.0.0 / *)", meaning: "Listening on every network interface, so other devices can connect."),
            Term(term: "localhost (127.0.0.1)", meaning: "Only reachable from this Mac."),
            Term(term: "Stop", meaning: "Sends SIGTERM, the same as pressing Ctrl-C in the terminal that started it."),
        ]
    )

    static let cleanup = SectionGuide(
        title: "Understanding Smart Clean",
        summary: "One scan across every kind of junk Mac Vitals knows about, with a one-click clean for the parts that are safe. Everything goes to the Trash first, and you can put it back.",
        healthy: [
            "A few GB of caches and logs is normal. Apps rebuild them.",
            "Developer Macs collect tens of GB of build data and old dependencies. That's where the big wins usually are.",
        ],
        culprits: [
            "Xcode build data and simulators grow quietly over months.",
            "node_modules and virtual environments left behind in old projects.",
            "Installers left in Downloads after you've installed the app.",
        ],
        fixes: [
            "\"Clean safe items\" removes only things that rebuild or re-download on their own.",
            "Use Junk to review everything, including items marked Review and Careful.",
            "Changed your mind? Recent cleanups has Put Back.",
        ],
        glossary: [
            Term(term: "Safe", meaning: "Rebuilt or re-downloaded automatically when needed. Pre-selected."),
            Term(term: "Review", meaning: "Probably not needed, but worth a quick look. Not pre-selected."),
            Term(term: "Careful", meaning: "Can't be undone (like emptying the Trash). Never pre-selected."),
            Term(term: "Put back", meaning: "Moves cleaned items from the Trash back to where they were."),
        ]
    )

    static let uninstaller = SectionGuide(
        title: "Understanding the Uninstaller",
        summary: "Dragging an app to the Trash leaves its data behind: caches, settings, saved windows, sometimes gigabytes. The Uninstaller removes the app and everything it kept in your Library, and shows you exactly what before it does.",
        healthy: [
            "Apps you haven't opened in months are the easiest wins.",
            "An app's data can be bigger than the app itself (chat apps, browsers, editors).",
        ],
        culprits: [
            "Apps installed for one task and never opened again.",
            "Leftovers from apps you deleted by dragging to the Trash.",
        ],
        fixes: [
            "Filter to \"Not used in 6 months\" and sort by size.",
            "Untick anything in the uninstall list you want to keep, such as settings, in case you reinstall.",
            "Changed your mind? Put Back in Smart Clean › Recent cleanups restores the app and its data.",
        ],
        glossary: [
            Term(term: "Data", meaning: "What an app keeps in your Library: caches, settings, saved windows, sandbox data."),
            Term(term: "Last opened", meaning: "From Spotlight. \"No record\" can mean never opened, or Spotlight didn't track it."),
            Term(term: "Leftovers", meaning: "Data from apps that aren't installed anymore. Found by matching bundle IDs exactly."),
        ]
    )

    static let startup = SectionGuide(
        title: "Understanding Startup Items",
        summary: "Things that start automatically when you log in or run in the background: apps' menu bar helpers, updaters, sync tools and system services.",
        healthy: [
            "A handful is normal. Most are updaters and menu bar helpers.",
            "\"Running\" doesn't mean it's using much. Check the Apps page for what's actually busy.",
        ],
        culprits: [
            "Updaters for apps you rarely use, running all the time.",
            "Broken items left behind by deleted apps.",
            "Helpers you forgot you installed.",
        ],
        fixes: [
            "Remove broken items. Their apps are already gone.",
            "Switch off background helpers you don't need. It's reversible anytime.",
            "Items macOS controls (Open at Login, embedded helpers, system services) open System Settings › Login Items.",
        ],
        glossary: [
            Term(term: "Opens at login (Login item)", meaning: "An app or menu bar helper that launches when you log in."),
            Term(term: "Background helper (Agent)", meaning: "A small program that runs in the background for you: updaters, sync, menu bar extras."),
            Term(term: "System service (Daemon)", meaning: "Runs for every user with extra privileges. Changing it needs an admin password."),
            Term(term: "Broken", meaning: "Its program no longer exists, usually because the app was deleted."),
            Term(term: "Allow in the Background", meaning: "The macOS switch in System Settings › Login Items that permits a helper to run."),
        ]
    )

    static let protection = SectionGuide(
        title: "Understanding Protection",
        summary: "Whether the security built into macOS is switched on, and whether anything starting automatically looks out of place. Mac Vitals checks and explains; it isn't antivirus.",
        healthy: [
            "FileVault, Gatekeeper and System Integrity Protection are on. They're on by default on a new Mac.",
            "Security fixes and malware definitions install automatically, so XProtect stays current.",
            "Startup items come from Apple, verified developers, or a package manager like Homebrew.",
            "The firewall being off is macOS's default. Turn it on if you use public Wi-Fi.",
        ],
        culprits: [
            "Adware installed alongside free downloads, usually as a startup item with no verified developer.",
            "Scripts hidden in dot-folders or temporary folders that run at login.",
            "Configuration profiles that lock your browser's home page or search engine.",
            "Security settings switched off to install something, then never switched back on.",
        ],
        fixes: [
            "Use each row's button to open the exact setting in System Settings.",
            "Remove startup items you don't recognize in Startup Items, and their apps with the Uninstaller.",
            "Remove configuration profiles you didn't add in System Settings › General › Device Management.",
            "For a deeper scan, use a dedicated anti-malware app.",
        ],
        glossary: [
            Term(term: "XProtect", meaning: "The malware scanner built into macOS. Apple updates what it looks for every few weeks."),
            Term(term: "Gatekeeper", meaning: "Checks apps the first time they open and blocks ones that aren't from identified developers."),
            Term(term: "SIP (System Integrity Protection)", meaning: "Stops anything, even with your password, from modifying macOS itself."),
            Term(term: "FileVault", meaning: "Full-disk encryption. Without your password, your data is unreadable."),
            Term(term: "Verified developer", meaning: "Signed with a Developer ID or through the Mac App Store, so Apple knows who made it."),
            Term(term: "Ad hoc signature", meaning: "Signed on the machine that built it, not by a known developer. Normal for open-source tools."),
            Term(term: "Launch agent / daemon", meaning: "A program macOS starts automatically, for you (agent) or for every user (daemon)."),
        ]
    )

    static let updates = SectionGuide(
        title: "Understanding Updates",
        summary: "Which of your apps have newer versions, checked at the source: each developer's own update feed, the App Store, and Homebrew.",
        healthy: [
            "Most apps up to date. Updates fix bugs and, often, security holes.",
            "Apps marked \"updates themselves\" (Chrome, Microsoft, VS Code…) check when you open them.",
        ],
        culprits: [
            "Apps you rarely open, which never get the chance to update themselves.",
            "Automatic updates switched off in an app's settings.",
            "Apps that need a newer macOS for their latest version.",
        ],
        fixes: [
            "Update: Mac Vitals downloads it, checks it's signed by the same developer as the app you have, moves the old version to the Trash and reopens the app.",
            "App Store apps open in the App Store, which does the update.",
            "If macOS asks, allow App Management once so Mac Vitals can replace apps.",
        ],
        glossary: [
            Term(term: "Update feed (Sparkle appcast)", meaning: "A list of versions a developer publishes. The app's own updater reads the same list."),
            Term(term: "Same developer", meaning: "The update must carry the same Apple-issued Team ID as the installed app, or it isn't installed."),
            Term(term: "Homebrew cask", meaning: "An app installed with Homebrew. Updated with brew upgrade."),
            Term(term: "Critical update", meaning: "Marked important by the developer, usually a security fix."),
        ]
    )

    static let duplicates = SectionGuide(
        title: "Understanding Duplicates",
        summary: "Files whose contents are exactly the same, byte for byte, in the folders you choose, and how much space removing the extra copies would really free.",
        healthy: [
            "A few duplicates is normal: the same photo saved twice, an attachment downloaded again.",
            "Copies made with Finder's Duplicate often share their data on disk (APFS), so they take no extra space. Mac Vitals sets those aside.",
        ],
        culprits: [
            "Downloading the same file more than once (\"Report (1).pdf\").",
            "Photos and videos imported or exported twice.",
            "Old backups copied into Documents or iCloud Drive.",
        ],
        fixes: [
            "Mac Vitals picks the copy to keep: the one in Documents, Pictures and the like, with the original name, usually the oldest. Change any with the checkboxes.",
            "One copy of every file always stays; you can't select them all.",
            "Everything goes to the Trash first. Removing a file from iCloud Drive removes it from your other devices too.",
        ],
        glossary: [
            Term(term: "Byte for byte", meaning: "Compared by content (SHA-256 fingerprint), not by name or date."),
            Term(term: "Shares space (APFS clone)", meaning: "A copy that points to the same data on disk as the original until one is edited. Removing it frees nothing."),
            Term(term: "Hard link", meaning: "One file with two names. Not a duplicate, and not counted."),
        ]
    )

    static let screenshots = SectionGuide(
        title: "Understanding Screenshots",
        summary: "Every screenshot in your Photos library (including ones from your iPhone) or saved as a file, so you can clear out the ones you no longer need.",
        healthy: [
            "Recent screenshots you're still using.",
            "A few you keep on purpose: tickets, receipts, references.",
        ],
        culprits: [
            "Screenshots taken to share once and never looked at again.",
            "iPhone screenshots syncing through iCloud Photos and taking up space on every device.",
        ],
        fixes: [
            "Filter to \"Older than a month\" and select all, then deselect the few you want.",
            "Or press Review and go one at a time: → keep, ⌫ delete, ← back.",
            "Library deletions go to Photos' Recently Deleted for 30 days; file deletions go to the Trash.",
        ],
        glossary: [
            Term(term: "Photos Library", meaning: "Screenshots in Photos, found by the screenshot tag Photos adds."),
            Term(term: "Files", meaning: "Screenshot files anywhere in your home folder, found by the tag macOS adds to every screenshot."),
            Term(term: "Recently Deleted", meaning: "Photos keeps deleted items there for 30 days before removing them for good."),
        ]
    )

    static let maintenance = SectionGuide(
        title: "Understanding Maintenance",
        summary: "Fixes for specific problems, each listed by the symptom it solves. macOS maintains itself, so none of these need running on a schedule.",
        healthy: [
            "You don't need to run anything here unless something is wrong.",
            "Local Time Machine snapshots come and go on their own; macOS removes them when it needs space.",
        ],
        culprits: [
            "A stuck Finder or Dock after a crash or an update.",
            "Stale saved data: DNS after switching networks, thumbnails, the \"Open With\" list.",
            "A damaged Spotlight index, usually after a migration or a crash.",
        ],
        fixes: [
            "Find the symptom you're seeing and press its button.",
            "Tasks with a lock ask for your password through macOS, on behalf of Mac Vitals.",
            "Rebuilding Spotlight makes your Mac busy for a few hours; do it plugged in, before a break.",
        ],
        glossary: [
            Term(term: "DNS cache", meaning: "Saved addresses of websites your Mac has visited recently."),
            Term(term: "Launch Services", meaning: "macOS's list of installed apps and which files each one opens."),
            Term(term: "Local snapshot", meaning: "A Time Machine restore point kept on your Mac between backups."),
            Term(term: "Spotlight index", meaning: "The catalog Spotlight searches instead of reading every file each time."),
        ]
    )

    static let spaceLens = SectionGuide(
        title: "Understanding Space Lens",
        summary: "A map of where your disk space goes. The folder you're in is in the middle; each ring around it is one level deeper. The bigger the slice, the more space it takes.",
        healthy: [
            "Your Library folder is often one of the biggest. Apps keep caches, data and iPhone backups there.",
            "Big slices aren't bad by themselves. Photos, music and projects are supposed to take space.",
            "Files not downloaded from iCloud don't take space on this Mac, so they count as zero.",
        ],
        culprits: [
            "Old videos, disk images and virtual machines you forgot about.",
            "Developer folders: node_modules, build folders, simulators and package caches.",
            "Downloads that were never cleaned up.",
            "Old iPhone backups and Messages attachments in Library.",
        ],
        fixes: [
            "Click a slice to open it; click the middle to go back out.",
            "Hover a row for Show in Finder and Move to Trash. Everything goes to the Trash first, so you can put it back.",
            "For apps, use the Uninstaller; it removes their leftovers too. For caches and build data, Junk is safer.",
        ],
        glossary: [
            Term(term: "Size on disk", meaning: "Space a file actually uses, which can differ from its length (compression, sparse files)."),
            Term(term: "Smaller files", meaning: "All the files in a folder beyond its 12 largest, added together."),
            Term(term: "macOS and hidden space", meaning: "Whole-Mac view only: space used by macOS itself, local Time Machine snapshots, and folders Mac Vitals can't read."),
            Term(term: "Hard link", meaning: "One file that appears in several places. Counted once."),
        ]
    )

    static let junk = SectionGuide(
        title: "Understanding Junk",
        summary: "Everything Mac Vitals found that you could remove, grouped by what it is, with what happens if you remove it.",
        healthy: [
            "Only Safe items are selected to start with.",
            "Nothing inside macOS itself is ever touched.",
        ],
        culprits: [],
        fixes: [
            "Expand a group to pick individual items.",
            "Items move to the Trash, so space is freed once the Trash is emptied (Mac Vitals can empty just what it cleaned).",
        ],
        glossary: [
            Term(term: "DerivedData", meaning: "Xcode's per-project build files. Safe; the next build is just slower."),
            Term(term: "Device support", meaning: "Debug symbols for iOS versions you've connected. Re-downloaded when needed."),
            Term(term: "node_modules / .venv / target", meaning: "A project's installed dependencies or build output. Your code isn't touched; reinstall when you return."),
        ]
    )
}
