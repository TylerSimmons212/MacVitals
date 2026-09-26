import SwiftUI

/// Extensions: every browser extension and system add-on, what each can do, and which are
/// worth a second look. Browser extensions are removed in the browser (the only safe place);
/// leftover add-ons can go to the Trash.
struct ExtensionsView: View {
    @Environment(ExtensionsModel.self) private var model
    @Environment(CleanupEngine.self) private var engine
    @Environment(Permissions.self) private var permissions
    @AppStorage("extensions.tab") private var showSystem = false
    @State private var copiedFor: BrowserExtension.Browser?
    @State private var pendingRemoval: SystemAddOn?

    var body: some View {
        SectionScroll {
            if let record = engine.lastRecord {
                CleanupResultBanner(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            hero.entrance()
            Picker("Show", selection: $showSystem) {
                Text("Browser Extensions (\(model.browserExtensions.count))").tag(false)
                Text("System Add-ons (\(model.addOns.count))").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().pointerStyle(.link)
            .frame(maxWidth: .infinity)
            if model.phase == .ready {
                if showSystem { systemTab } else { browserTab }
            }
        }
        .task { if model.phase == .idle { await model.load() } }
        .animation(.smooth, value: showSystem)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: engine.lastRecord?.id)
        .confirmationDialog(pendingRemoval.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { addOn in
            Button("Move to Trash", role: .destructive) {
                let item = addOn
                if item.path?.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) == true {
                    Task { await model.remove(item, engine: engine) }
                } else {
                    permissions.request(.finder) { Task { await model.remove(item, engine: engine) } }
                }
            }
        } message: { addOn in
            Text(addOn.kind == .audioDriver
                 ? "It goes to the Trash. The sound device disappears after you restart your Mac."
                 : "It goes to the Trash, so you can put it back.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        let flagged = model.worthALook.count
        let leftovers = model.leftovers.count
        let tint: Color = model.worthALook.contains { $0.level == .suspicious } ? .orange : Theme.cleanup
        return HStack(spacing: 22) {
            ZStack {
                Circle().fill(tint.opacity(0.12))
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 40)).foregroundStyle(tint.gradient)
            }
            .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if model.phase != .ready { Text("Looking at your extensions…") }
                    else if flagged > 0 { Text("\(flagged) extension\(flagged == 1 ? " is" : "s are") worth a look") }
                    else if leftovers > 0 { Text("\(leftovers) leftover add-on\(leftovers == 1 ? "" : "s") to tidy up") }
                    else { Text("Nothing unusual") }
                }
                .font(.title2.weight(.semibold))
                Text("Extensions add features to your browser and to macOS. Most are fine. The ones worth a look were installed by another program, are forced on by a policy (a common adware trick), or belong to apps you've deleted.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let last = model.lastCheck {
                        Text("Checked \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button { Task { await model.load() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                        .disabled(model.phase == .loading)
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    // MARK: Browser

    @ViewBuilder
    private var browserTab: some View {
        if model.browserExtensions.isEmpty {
            Text("No browser extensions found in Chrome, Arc, Brave, Edge, Vivaldi, Opera, Firefox or Safari.")
                .foregroundStyle(.secondary).cardStyle(padding: 16)
        }
        ForEach(model.browsers, id: \.self) { browser in
            let items = model.browserExtensions.filter { $0.browser == browser }
            Card(browser.name, systemImage: "safari", tint: Theme.cleanup) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 40) }
                        ExtensionRow(item: item)
                    }
                }
            } accessory: {
                if browser != .safari {
                    Button(copiedFor == browser ? "Address copied: paste it in \(browser.name)" : "Open \(browser.name)'s Extensions") {
                        model.openExtensionsPage(in: browser)
                        copiedFor = browser
                    }
                    .buttonStyle(.link).font(.callout).pointerStyle(.link)
                    .help("Browsers don't let other apps open this page, so Mac Vitals copies its address; paste it into the address bar.")
                } else {
                    Text("Turn on or off in Safari › Settings › Extensions").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: System

    @ViewBuilder
    private var systemTab: some View {
        ForEach(SystemAddOn.Kind.allCases, id: \.self) { kind in
            let items = model.addOns.filter { $0.kind == kind }
            if !items.isEmpty {
                Card(kind.title, systemImage: kind.icon, tint: Theme.cleanup) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind.explanation).font(.callout).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, addOn in
                                if index > 0 { Divider().padding(.leading, 40) }
                                AddOnRow(addOn: addOn) { pendingRemoval = addOn }
                            }
                        }
                    }
                } accessory: {
                    if kind == .systemExtension {
                        Button("Manage in Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .buttonStyle(.link).font(.callout).pointerStyle(.link)
                        .help("System Settings › General › Login Items & Extensions")
                    }
                }
            }
        }
    }
}

// MARK: - Rows

private struct ExtensionRow: View {
    let item: BrowserExtension
    @Environment(ExtensionsModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.level >= .review ? "exclamationmark.triangle.fill" : "puzzlepiece.extension")
                    .foregroundStyle(item.level == .suspicious ? .orange : item.level == .review ? .yellow : .secondary)
                    .font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                        if item.enabled == false {
                            Text("Off").font(.caption2.weight(.semibold)).glassChip()
                        }
                        if item.level >= .review {
                            Text(item.level == .suspicious ? "Worth a look" : "Check it's yours")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(item.level == .suspicious ? .orange : .yellow)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill((item.level == .suspicious ? Color.orange : .yellow).opacity(0.15)))
                        }
                    }
                    Text([item.source.label, item.hasBroadAccess ? "All websites" : nil, item.profile.map { "profile \($0)" },
                          item.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.tertiary)
                        .help(item.hasBroadAccess ? BrowserExtension.Concern.broadAccess.text : "")
                    // Only the real red flags get a line of their own; broad access is common and
                    // lives in the details line and "What it can do".
                    ForEach(item.concerns.filter { $0 != .disabled && $0 != .broadAccess }, id: \.self) { concern in
                        Label(concern.text, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if !item.access.isEmpty {
                    Button(expanded ? "Less" : "What it can do") { withAnimation(.spring(response: 0.35)) { expanded.toggle() } }
                        .buttonStyle(.link).font(.callout).pointerStyle(.link)
                }
                if item.storeURL != nil {
                    Button("Store Page") { model.openStorePage(item) }
                        .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                        .help("Opens its store page in \(item.browser.name), which has a Remove button")
                }
                if let path = item.path {
                    Button { ProcessController.revealInFinder(path) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                        .help(item.browser == .safari ? "Show the app it comes with" : "Show its files")
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.access, id: \.self) { access in
                        Label(access, systemImage: "checkmark.circle").font(.callout)
                    }
                    if item.hasBroadAccess {
                        Text(BrowserExtension.Concern.broadAccess.text).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary = item.summary, item.browser != .firefox {
                        Text(summary).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    Text(verbatim: "ID: \(item.extensionID)").font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .padding(.leading, 40)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 9)
    }
}

private struct AddOnRow: View {
    let addOn: SystemAddOn
    let remove: () -> Void

    private var statusText: (String, Color) {
        switch addOn.status {
        case .inUse(let app): (app.map { "From \($0)" } ?? "In use", .secondary)
        case .leftover: ("Its app seems to be gone", .orange)
        case .obsolete: ("No longer used by macOS", .orange)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: addOn.kind.icon).foregroundStyle(.secondary).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(addOn.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(statusText.0).foregroundStyle(statusText.1)
                    if let detail = addOn.detail { Text("· \(detail)").foregroundStyle(.tertiary) }
                    if let version = addOn.version { Text("· v\(version)").foregroundStyle(.tertiary) }
                }
                .font(.caption)
                if let id = addOn.bundleID {
                    Text(verbatim: id).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let path = addOn.path {
                Button { ProcessController.revealInFinder(path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link).help("Show in Finder")
            }
            if addOn.isRemovable {
                Button("Remove…", action: remove)
                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                    .help(addOn.path?.hasPrefix("/Library") == true ? "Installed for all users: Finder will ask for your password" : "Move to the Trash")
            }
        }
        .padding(.vertical, 9)
    }
}
