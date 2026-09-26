import SwiftUI

/// App updates from each app's own source: the developer's update feed (installed here after
/// checking it's signed by the same developer), the App Store, and Homebrew. Apps with their
/// own updaters are listed honestly as "updates itself" rather than guessed at.
struct UpdatesView: View {
    @Environment(UpdatesModel.self) private var model
    @Environment(Permissions.self) private var permissions

    var body: some View {
        SectionScroll {
            hero.entrance()
            stats.entrance(delay: 0.04)
            if model.phase == .ready || !model.apps.isEmpty {
                availableCard.entrance(delay: 0.08)
                if !model.selfUpdating.isEmpty { selfUpdatingCard.entrance(delay: 0.1) }
                upToDateCard.entrance(delay: 0.12)
                if !model.uncheckable.isEmpty || !model.failedChecks.isEmpty || !model.needsNewerMacOS.isEmpty {
                    otherCard.entrance(delay: 0.14)
                }
            }
        }
        .task {
            if model.phase == .idle || (model.lastCheck.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true) {
                await model.check()
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.available.map(\.id))
        .animation(.smooth, value: model.phase)
    }

    // MARK: Hero

    private var hero: some View {
        let count = model.available.count
        let critical = model.available.filter { model.checks[$0.path]?.isCritical == true }.count
        let tint: Color = model.phase != .ready ? .blue : count == 0 ? .green : critical > 0 ? .orange : .blue
        return HStack(spacing: 22) {
            ZStack {
                GaugeRing(fraction: model.checkedCount == 0 ? 0 : Double(model.checkedCount - count) / Double(model.checkedCount), color: tint, lineWidth: 12)
                if model.phase == .checking && model.apps.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 0) {
                        RollingText("\(count)", size: 30)
                        Text(count == 1 ? "update" : "updates").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if model.phase == .checking && model.checks.isEmpty {
                        Text("Checking for updates…")
                    } else if count == 0 {
                        Text("Your apps are up to date")
                    } else {
                        Text("\(count) update\(count == 1 ? "" : "s") available")
                    }
                }
                .font(.title2.weight(.semibold))
                .contentTransition(.interpolate)
                Text("Mac Vitals checks each app's own update feed, the App Store and Homebrew. Updates from developers are installed only after checking they're signed by the same developer as the app you have.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if !model.oneClick.isEmpty {
                        Button {
                            Task { await model.updateAll() }
                        } label: {
                            Label("Update All (\(model.oneClick.count))", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .pointerStyle(.link)
                        .help("Installs the updates Mac Vitals can do itself. App Store updates open the App Store.")
                    }
                    if let last = model.lastCheck {
                        Text("Checked \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await model.check() }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                    .disabled(model.phase == .checking)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    private var stats: some View {
        HStack(spacing: 16) {
            DetailStat(label: "Apps checked", term: "Feeds, App Store, Homebrew",
                       value: model.apps.isEmpty ? "—" : "\(model.checkedCount)",
                       caption: "of \(model.apps.count) installed", rolls: true)
            DetailStat(label: "From developers", term: "Sparkle feeds",
                       value: "\(model.apps.filter { if case .sparkle = $0.source { true } else { false } }.count)",
                       caption: "Installed here, signature-checked")
            DetailStat(label: "App Store", term: "Mac App Store",
                       value: "\(model.apps.filter { $0.source == .appStore }.count)",
                       caption: "Updated in the App Store")
            DetailStat(label: "Update themselves", term: "Own updaters",
                       value: "\(model.selfUpdating.count)",
                       caption: "Chrome, Microsoft, Electron…")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Cards

    private var availableCard: some View {
        Card("Updates available", systemImage: "arrow.down.app", tint: .blue) {
            if model.phase == .checking && model.checks.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Asking developers, the App Store and Homebrew…").foregroundStyle(.secondary)
                }
            } else if model.available.isEmpty && !model.installs.values.contains(where: { if case .done = $0 { true } else { false } }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title3)
                    Text("Everything Mac Vitals can check is on the latest version.").foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    let rows = model.available + model.apps.filter { if case .done = model.installs[$0.path] { true } else { false } }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 44) }
                        UpdateRow(app: app, check: model.checks[app.path], state: model.installs[app.path])
                    }
                }
            }
        }
    }

    private var selfUpdatingCard: some View {
        Card("Update themselves", systemImage: "arrow.triangle.2.circlepath", tint: .secondary) {
            VStack(alignment: .leading, spacing: 10) {
                Text("These have their own updaters, which check when you open them. Mac Vitals can't see which version is newest, so it doesn't guess.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                AppChipGrid(apps: model.selfUpdating) { app in
                    if case .selfUpdating(let by) = app.source { by } else { app.source.label }
                }
            }
        }
    }

    private var upToDateCard: some View {
        Card("Up to date", systemImage: "checkmark.circle", tint: .green) {
            if model.upToDate.isEmpty {
                Text(model.phase == .checking ? "Checking…" : "Nothing to show yet.").foregroundStyle(.secondary)
            } else {
                AppChipGrid(apps: model.upToDate) { app in
                    "\(app.version) · \(app.source.label)"
                }
            }
        }
    }

    private var otherCard: some View {
        Card("Can't check", systemImage: "questionmark.circle", tint: .secondary) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.needsNewerMacOS.isEmpty {
                    ForEach(model.needsNewerMacOS) { app in
                        if case .needsNewerMacOS(let version) = model.checks[app.path]?.status {
                            Label("\(app.name) \(model.checks[app.path]?.latestVersion ?? "") needs macOS \(version) or later.", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                                .font(.callout)
                        }
                    }
                }
                ForEach(model.failedChecks) { app in
                    if case .failed(let reason) = model.checks[app.path]?.status {
                        Label("\(app.name): \(reason)", systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !model.uncheckable.isEmpty {
                    Text("No update information: these don't publish an update feed Mac Vitals can read. Check the developer's website.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    AppChipGrid(apps: model.uncheckable) { $0.version }
                }
            }
        }
    }
}

// MARK: - Rows

private struct UpdateRow: View {
    let app: UpdatableApp
    let check: UpdateCheck?
    let state: UpdatesModel.InstallState?
    @Environment(UpdatesModel.self) private var model
    @Environment(Permissions.self) private var permissions
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                AppIconView(bundlePath: app.path, kind: .application, size: 32)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(app.name).font(.body.weight(.medium))
                        if check?.isCritical == true {
                            Text("Important").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                                .help("The developer marked this update as critical, usually for security")
                        }
                    }
                    HStack(spacing: 6) {
                        Text(app.version).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(check?.latestVersion ?? "?").fontWeight(.semibold)
                        Text("·").foregroundStyle(.tertiary)
                        Text(app.source.label).foregroundStyle(.secondary)
                        if let size = check?.size, size > 0 {
                            Text("·").foregroundStyle(.tertiary)
                            Text(Fmt.bytes(size)).foregroundStyle(.secondary)
                        }
                        if let date = check?.releaseDate {
                            Text("·").foregroundStyle(.tertiary)
                            Text(date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                    status
                }
                Spacer(minLength: 8)
                if check?.notes != nil || check?.releaseNotesURL != nil {
                    Button(showNotes ? "Hide Notes" : "What's New") { withAnimation(.spring(response: 0.35)) { showNotes.toggle() } }
                        .buttonStyle(.link).font(.callout).pointerStyle(.link)
                }
                action
            }
            if showNotes {
                VStack(alignment: .leading, spacing: 6) {
                    if let notes = check?.notes {
                        Text(notes).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let url = check?.releaseNotesURL {
                        Link("Full release notes", destination: url).font(.callout).pointerStyle(.link)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .padding(.leading, 44)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .working(let step)?:
            HStack(spacing: 8) {
                switch step {
                case .downloading(let fraction):
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        LayerBar(fraction: fraction, color: .blue)
                    }
                    .frame(width: 140, height: 5)
                    Text("Downloading \(Int(fraction * 100))%")
                case .verifying: ProgressView().controlSize(.mini); Text("Checking the developer's signature…")
                case .installing: ProgressView().controlSize(.mini); Text("Installing…")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        case .updating(let text)?:
            Label(text, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
        case .done(let text)?:
            Label(text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let failure)?:
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .working?, .updating?:
            ProgressView().controlSize(.small)
        case .done?:
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) }
                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
        case .failed(let failure)?:
            HStack(spacing: 6) {
                switch failure {
                case .needsAppManagement:
                    Button("Allow & Update") { permissions.request(.appManagement) { Task { await model.retry(app) } } }
                        .buttonStyle(.glassProminent).controlSize(.small).pointerStyle(.link)
                case .needsPassword:
                    Button("Update with Finder…") { permissions.request(.finder) { Task { await model.retry(app, viaFinder: true) } } }
                        .buttonStyle(.glassProminent).controlSize(.small).pointerStyle(.link)
                        .help("Finder asks for your password to replace an app installed for all users")
                case .cantVerifyInstalled, .unsupportedFormat, .wrongDeveloper, .invalidSignature:
                    if let url = check?.downloadURL {
                        Button("Download…") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                            .help("Opens the download in your browser, so you can install it yourself")
                    }
                default:
                    Button("Try Again") { model.dismissFailure(app); Task { await model.update(app) } }
                        .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                }
                Button { model.dismissFailure(app) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link).help("Dismiss")
            }
        case nil:
            Button(app.source == .appStore ? "Update in App Store" : "Update") {
                Task { await model.update(app) }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .pointerStyle(.link)
        }
    }
}

/// Compact wrapping grid of apps (icon, name, one detail line).
private struct AppChipGrid: View {
    let apps: [UpdatableApp]
    let detail: (UpdatableApp) -> String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    AppIconView(bundlePath: app.path, kind: .application, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name).font(.callout).lineLimit(1)
                        Text(detail(app)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(app.path)
            }
        }
    }
}
