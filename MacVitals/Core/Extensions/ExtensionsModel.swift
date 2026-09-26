import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class ExtensionsModel {
    enum Phase: Equatable { case idle, loading, ready }

    private(set) var phase: Phase = .idle
    private(set) var browserExtensions: [BrowserExtension] = []
    private(set) var addOns: [SystemAddOn] = []
    private(set) var lastCheck: Date?

    var worthALook: [BrowserExtension] { browserExtensions.filter { $0.level >= .review } }
    var leftovers: [SystemAddOn] { addOns.filter { $0.status == .leftover || $0.status == .obsolete } }
    var browsers: [BrowserExtension.Browser] {
        BrowserExtension.Browser.allCases.filter { browser in browserExtensions.contains { $0.browser == browser } }
    }

    /// Reads small settings files and two system lists: quick and light.
    func load() async {
        phase = .loading
        async let browser = Task.detached(priority: .userInitiated) { BrowserExtensions.all() }.value
        async let system = Task.detached(priority: .utility) { SystemAddOns.all() }.value
        browserExtensions = await browser
        addOns = await system
        lastCheck = Date()
        phase = .ready
    }

    /// Leftovers in your own Library go to the Trash directly; ones installed for all users
    /// go through Finder (your password).
    func remove(_ addOn: SystemAddOn, engine: CleanupEngine) async {
        guard addOn.isRemovable, let path = addOn.path else { return }
        let item = JunkItem(path: path, name: addOn.name, detail: addOn.kind.title, size: 0, tier: .review)
        if path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) {
            let record = await Task.detached(priority: .userInitiated) { CleanupRemover.remove([item], permanently: false) }.value
            engine.record(record)
        } else {
            await engine.removeWithFinder([item])
        }
        addOns.removeAll { $0.path != nil && !FileManager.default.fileExists(atPath: $0.path!) }
    }

    /// Browsers don't let other apps open their extensions page, so: copy its address and
    /// open the browser; you paste it.
    func openExtensionsPage(in browser: BrowserExtension.Browser) {
        let address: String? = switch browser {
        case .chrome, .chromium: "chrome://extensions"
        case .arc: "arc://extensions"
        case .brave: "brave://extensions"
        case .edge: "edge://extensions"
        case .vivaldi: "vivaldi://extensions"
        case .opera: "opera://extensions"
        case .firefox: "about:addons"
        case .safari: nil
        }
        if let address {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, _ in }
        }
    }

    func openStorePage(_ item: BrowserExtension) {
        guard let url = item.storeURL else { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.browser.bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
