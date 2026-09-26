import SwiftUI

/// Protection: is macOS's built-in security switched on, and is anything suspicious starting
/// automatically? Honest by design: it checks and explains, and says plainly that it isn't
/// antivirus (macOS already runs XProtect for that).
struct ProtectionView: View {
    @Environment(ProtectionModel.self) private var model
    @Environment(Router.self) private var router
    @State private var unlocking = false

    var body: some View {
        SectionScroll {
            hero.entrance()
            stats.entrance(delay: 0.04)
            defencesCard.entrance(delay: 0.08)
            startupCard.entrance(delay: 0.1)
            appsCard.entrance(delay: 0.12)
            honestyCard.entrance(delay: 0.14)
        }
        .task {
            // Checks are cheap but not free; reuse results for a few minutes.
            if model.phase == .idle || (model.lastCheck.map { Date().timeIntervalSince($0) > 300 } ?? true) {
                await model.check()
            }
        }
        .animation(.smooth, value: model.phase)
    }

    // MARK: Hero

    private var tint: Color {
        if model.phase != .ready { return Theme.protection }
        if model.suspiciousCount > 0 { return .red }
        if model.attentionCount > 0 { return .orange }
        return .green
    }

    private var hero: some View {
        let total = max(model.coreDefences.count, 1)
        let on = model.coreDefencesOn
        let recommendations = model.defences.filter { $0.status == .recommended }.count
        return HStack(spacing: 22) {
            ZStack {
                GaugeRing(fraction: model.phase == .idle ? 0 : Double(on) / Double(total), color: tint, lineWidth: 12)
                if model.phase == .ready || !model.defences.isEmpty {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            RollingText("\(on)", size: 30)
                            Text("/\(model.coreDefences.count)").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        }
                        Text("defences on").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "checkmark.shield").font(.system(size: 34)).foregroundStyle(Theme.protection)
                        .symbolEffect(.pulse, isActive: model.phase == .checking)
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if model.phase != .ready && model.defences.isEmpty {
                        Text("Checking your Mac's defences…")
                    } else if model.suspiciousCount > 0 {
                        Text("\(model.suspiciousCount) startup item\(model.suspiciousCount == 1 ? " looks" : "s look") suspicious")
                    } else if model.attentionCount > 0 {
                        Text("\(model.attentionCount) protection\(model.attentionCount == 1 ? " is" : "s are") off")
                    } else if recommendations > 0 {
                        Text("Your Mac's defences are on")
                    } else {
                        Text("Your Mac is well protected")
                    }
                }
                .font(.title2.weight(.semibold))
                .contentTransition(.interpolate)
                Text("Mac Vitals checks the security built into macOS and everything that starts automatically. It isn't antivirus: macOS's own malware scanner, XProtect, already runs in the background.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if recommendations > 0 && model.attentionCount == 0 {
                        InfoChip(text: "\(recommendations) recommendation\(recommendations == 1 ? "" : "s") below", icon: "lightbulb", tint: .orange)
                    }
                    if let last = model.lastCheck {
                        Text("Checked \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await model.check() }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerStyle(.link)
                    .disabled(model.phase == .checking)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    // MARK: Stats

    private var stats: some View {
        let flagged = model.flaggedStartup.count
        return HStack(spacing: 16) {
            DetailStat(label: "Defences on", term: "Core protections",
                       value: model.defences.isEmpty ? "—" : "\(model.coreDefencesOn) of \(model.coreDefences.count)",
                       tint: model.defences.contains { $0.isCoreDefence && $0.status == .off } ? .orange : nil,
                       caption: "Encryption, Gatekeeper, SIP, updates, XProtect, firewall")
            DetailStat(label: "Starts automatically", term: "Launch items",
                       value: model.startup.isEmpty ? "—" : "\(model.startup.count)",
                       tint: model.suspiciousCount > 0 ? .red : nil,
                       caption: model.startup.isEmpty ? "Checking…" : flagged == 0 ? "All look normal" : "\(flagged) worth a look",
                       rolls: true)
            DetailStat(label: "Apps checked", term: "Code signatures",
                       value: model.appsChecked == 0 ? "—" : "\(model.appsChecked)",
                       caption: model.appsChecked == 0 ? "Checking…" : model.unverifiedApps.isEmpty ? "All from verified developers" : "\(model.unverifiedApps.count) without a verified developer",
                       rolls: true)
            DetailStat(label: "Remote access", term: "Sharing",
                       value: sharingValue,
                       caption: "Other computers connecting in")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sharingValue: String {
        guard let sharing = model.defences.first(where: { $0.id == .sharing }) else { return "—" }
        return sharing.status == .on ? "Off" : "On"
    }

    // MARK: Defences

    private var defencesCard: some View {
        let order: [DefenceCheck.Status] = [.off, .recommended, .unknown, .info, .checking, .on]
        let sorted = model.defences.enumerated().sorted {
            let a = order.firstIndex(of: $0.element.status) ?? 9, b = order.firstIndex(of: $1.element.status) ?? 9
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        return Card("Built-in defences", systemImage: "shield.lefthalf.filled", tint: Theme.protection) {
            if sorted.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading macOS's security settings…").foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { Divider().padding(.leading, 40) }
                        DefenceRow(check: check)
                    }
                }
            }
        }
    }

    // MARK: Startup

    private var startupCard: some View {
        let flagged = model.flaggedStartup
        return Card("Things that start automatically", systemImage: "power.circle", tint: Theme.protection) {
            if model.startup.isEmpty && model.phase != .ready {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking each startup item's developer and location…").foregroundStyle(.secondary)
                }
            } else if flagged.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    AllClearLine(text: "All \(model.startup.count) startup items \(model.startupComplete ? "" : "Mac Vitals can see ")come from Apple, verified developers, or a package manager like Homebrew. This is where Mac adware usually hides, and nothing looks out of place.")
                    extensionsNote
                    completeListCallout
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Most Mac adware makes itself start automatically. These don't match what trustworthy apps usually do. That doesn't make them malware; if you recognize them, they're fine.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(flagged.enumerated()), id: \.element.id) { index, review in
                            if index > 0 { Divider().padding(.leading, 44) }
                            StartupReviewRow(review: review) { router.section = .startup }
                        }
                    }
                    extensionsNote
                    completeListCallout
                }
            }
        } accessory: {
            if model.phase == .ready {
                Button("Startup Items") { router.section = .startup }
                    .buttonStyle(.link).font(.callout).pointerStyle(.link)
            }
        }
    }

    /// Adware usually arrives as a browser extension too.
    @ViewBuilder
    private var extensionsNote: some View {
        let count = model.suspiciousExtensions.count
        if count > 0 {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.orange)
                Text("\(count) browser extension\(count == 1 ? " was" : "s were") forced on by a policy or installed outside the store: \(ListFormatter.localizedString(byJoining: model.suspiciousExtensions.prefix(3).map(\.name))).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Review") { router.section = .extensions }
                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        }
    }

    @ViewBuilder
    private var completeListCallout: some View {
        if !model.startupComplete && model.phase == .ready {
            CompleteStartupListCallout(isWorking: unlocking) {
                unlocking = true
                Task { await model.includeEverything(); unlocking = false }
            }
        }
    }

    // MARK: Apps

    private var appsCard: some View {
        Card("Apps without a verified developer", systemImage: "app.badge.checkmark", tint: Theme.protection) {
            if model.appsChecked == 0 && model.phase != .ready {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking app signatures…").foregroundStyle(.secondary)
                }
            } else if model.unverifiedApps.isEmpty {
                AllClearLine(text: "All \(model.appsChecked) apps are signed by developers Apple has verified.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Apple verifies developers before they can sign apps. Open-source and self-built apps often skip this, so it's not a problem by itself. Remove any you don't recognize.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(model.unverifiedApps.enumerated()), id: \.element.id) { index, app in
                            if index > 0 { Divider().padding(.leading, 44) }
                            UnverifiedAppRow(app: app) { router.section = .uninstaller }
                        }
                    }
                }
            }
        }
    }

    // MARK: Honesty

    private var honestyCard: some View {
        Card("If you think something's wrong", systemImage: "lifepreserver", tint: .secondary) {
            VStack(alignment: .leading, spacing: 8) {
                bullet("macOS's XProtect finds and removes known Mac malware on its own, as long as automatic updates are on.")
                bullet("Remove apps and startup items you don't recognize with the Uninstaller and Startup Items.")
                bullet("Pop-ups or a browser that keeps changing its home page usually mean an unwanted browser extension. Check your browser's extensions.")
                bullet("For a deeper scan, use a dedicated anti-malware app. Mac Vitals doesn't pretend to be one.")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Rows

private struct AllClearLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).font(.title3)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DefenceRow: View {
    let check: DefenceCheck
    @State private var expanded = false
    @State private var hovering = false

    private var icon: (String, Color) {
        switch check.status {
        case .on: ("checkmark.shield.fill", .green)
        case .off: ("xmark.shield.fill", .red)
        case .recommended: ("exclamationmark.shield.fill", .orange)
        case .info: ("info.circle.fill", .blue)
        case .checking: ("shield", .secondary)
        case .unknown: ("questionmark.circle", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if check.status == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon.0).foregroundStyle(icon.1).font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(check.title).font(.body.weight(.medium))
                    Text(check.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { withAnimation(.spring(response: 0.35)) { expanded.toggle() } } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                    .opacity(hovering || expanded ? 1 : 0.35)
                    .help("Why it matters, and the technical details")
                if let label = check.fixLabel, let url = check.fixURL {
                    Button(label) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .tint(check.status == .off ? .red : nil)
                        .pointerStyle(.link)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(check.why).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let technical = check.technical {
                        Text(verbatim: technical)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .padding(.leading, 40)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.03 : 0)))
        .onHover { hovering = $0 }
        .animation(.smooth, value: check.status)
    }
}

private struct StartupReviewRow: View {
    let review: PersistenceAudit.Review
    let manage: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let app = review.item.appPath, FileManager.default.fileExists(atPath: app) {
                        AppIconView(bundlePath: app, kind: .application, size: 28)
                    } else {
                        Image(systemName: "gearshape.2").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(review.item.name).font(.body.weight(.medium)).lineLimit(1)
                        Text(review.level == .suspicious ? "Suspicious" : "Worth a look")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(review.level == .suspicious ? .red : .orange)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill((review.level == .suspicious ? Color.red : .orange).opacity(0.15)))
                    }
                    Text(review.source).font(.caption).foregroundStyle(.tertiary)
                    ForEach(review.concerns, id: \.text) { concern in
                        Label(concern.text, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button { withAnimation(.spring(response: 0.35)) { expanded.toggle() } } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                    .help("Technical details")
                if let path = review.item.plistPath ?? review.target {
                    Button("Reveal") { ProcessController.revealInFinder(path) }
                        .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                }
                Button("Manage") { manage() }
                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                    .help("Turn it off or remove it in Startup Items")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    detail("Label", review.item.label)
                    if let plist = review.item.plistPath { detail("Plist", plist) }
                    if let target = review.target { detail("Runs", target) }
                    if let signer = review.signature?.signer { detail("Signer", signer) }
                    if let team = review.signature?.teamID { detail("Team ID", team) }
                }
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .padding(.leading, 44)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 10)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}

private struct UnverifiedAppRow: View {
    let app: AppSignatureAudit.Review
    let uninstall: () -> Void

    private var explanation: String {
        switch app.signature.trust {
        case .invalid: "Its signature doesn't match: the app was changed after its developer signed it. Reinstall it from the developer, or remove it."
        case .unsigned: "Not signed at all. Common for older or self-built apps."
        default: "Signed locally, not by a developer Apple has verified. Common for open-source and self-built apps."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(bundlePath: app.path, kind: .application, size: 28)
                .frame(width: 32, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                    if app.signature.trust == .invalid {
                        Text("Modified")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.red)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.15)))
                    }
                }
                Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: app.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Reveal") { ProcessController.revealInFinder(app.path) }
                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
            Button("Uninstall…") { uninstall() }
                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                .help("Opens the Uninstaller, which also finds its leftover files")
        }
        .padding(.vertical, 10)
    }
}
