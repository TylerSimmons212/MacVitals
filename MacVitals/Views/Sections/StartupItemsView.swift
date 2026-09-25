import SwiftUI

/// Startup Items: everything that starts automatically, in plain words: what it is, who made
/// it, how it runs, and whether it's running now. Your own helpers can be switched off here;
/// the rest link to the exact place in System Settings, because that's what macOS allows.
struct StartupItemsView: View {
    @Environment(StartupModel.self) private var model
    @Environment(CleanupEngine.self) private var engine
    @State private var pendingRemoval: StartupItem?

    var body: some View {
        SectionScroll {
            hero.entrance()
            stats.entrance(delay: 0.04)
            if let record = engine.lastRecord {
                CleanupResultBanner(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if !model.broken.isEmpty {
                brokenCard.entrance(delay: 0.06)
            }
            ForEach(StartupItem.Kind.allCases, id: \.self) { kind in
                let items = model.items(of: kind)
                if !items.isEmpty {
                    section(kind, items: items).entrance(delay: 0.1)
                }
            }
            HStack {
                Text("macOS controls some items only from System Settings. Mac Vitals takes you straight there.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items Settings") { model.openSystemSettings() }
                    .buttonStyle(.glass).pointerStyle(.link)
            }
            .padding(.top, 4)
        }
        .task { await model.scan() }
        .onChange(of: engine.putBackCount) { Task { await model.scan() } }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: model.items.map(\.id))
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: engine.lastRecord?.id)
        .confirmationDialog(pendingRemoval.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { item in
            Button("Move to Trash", role: .destructive) { Task { await model.remove(item, engine: engine) } }
        } message: { _ in
            Text("Its app is already gone, so this can't run anyway. It goes to the Trash, and you can put it back.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        let total = model.items.count
        let running = model.items.filter(\.isRunning).count
        let updaters = model.items.filter { $0.purpose.hasPrefix("Keeps") && $0.purpose.contains("up to date") }.count
        let broken = model.broken.count
        let tint: Color = broken > 0 ? .orange : Theme.cleanup
        return HStack(spacing: 22) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: total == 0 ? 0 : Double(running) / Double(total))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(total)")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        .rollingNumber(total)
                    Text("start automatically").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 14)
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                if model.phase == .scanning {
                    Text("Checking what starts automatically…").font(.title2.weight(.semibold))
                } else if broken > 0 {
                    Text("\(broken) startup item\(broken == 1 ? " is" : "s are") broken").font(.title2.weight(.semibold))
                    Text("Their apps have been deleted, but they're still set to start. They can't do anything anymore, so they're safe to remove.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(total) thing\(total == 1 ? "" : "s") start\(total == 1 ? "s" : "") automatically").font(.title2.weight(.semibold))
                    Text("\(running) running right now\(updaters > 0 ? ", \(updaters) of them just keep apps up to date" : ""). Fewer startup items means a faster login and less going on in the background.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 16) {
            DetailStat(label: "Open at login", term: "Login items", value: "\(model.items(of: .loginItem).count)",
                       caption: "Apps and menu bar helpers")
            DetailStat(label: "Background helpers", term: "Agents", value: "\(model.items(of: .agent).count)",
                       caption: "\(model.items(of: .agent).filter(\.isRunning).count) running now")
            DetailStat(label: "System services", term: "Daemons", value: "\(model.items(of: .daemon).count)",
                       caption: "Run for every user")
            DetailStat(label: "Broken", term: "App deleted", value: "\(model.broken.count)",
                       tint: model.broken.isEmpty ? nil : .orange,
                       caption: model.broken.isEmpty ? "Nothing left behind" : "Safe to remove")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Broken

    private var brokenCard: some View {
        Card("Broken: their apps are gone", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
            VStack(spacing: 0) {
                ForEach(Array(model.broken.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    StartupRow(item: item, busy: model.busy.contains(item.id)) {
                        if item.isUserManageable {
                            Button("Remove") { pendingRemoval = item }
                                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                        } else {
                            Button("Reveal") { ProcessController.revealInFinder(item.plistPath ?? "/Library/LaunchDaemons") }
                                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                                .help("Installed for all users. Removing it needs your admin password in Finder.")
                        }
                    }
                }
            }
        }
    }

    // MARK: Sections

    private func section(_ kind: StartupItem.Kind, items: [StartupItem]) -> some View {
        let title: String = switch kind {
        case .loginItem: "Apps that open at login"
        case .agent: "Background helpers"
        case .daemon: "System services"
        }
        let icon: String = switch kind {
        case .loginItem: "person.crop.circle.badge.checkmark"
        case .agent: "gearshape.2"
        case .daemon: "lock.shield"
        }
        return Card(title, systemImage: icon, tint: Theme.cleanup) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    StartupRow(item: item, busy: model.busy.contains(item.id)) {
                        if item.isUserManageable {
                            Toggle("Allowed", isOn: Binding(
                                get: { item.isEnabled },
                                set: { newValue in Task { await model.setEnabled(item, newValue) } }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .pointerStyle(.link)
                            .help(item.isEnabled ? "Turn off: stop it now and don't start it again" : "Turn back on")
                        } else {
                            Button("Manage…") { model.openSystemSettings() }
                                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                                .help("macOS only lets you change this in System Settings › Login Items")
                        }
                    }
                }
            }
        } accessory: {
            if kind == .daemon {
                Text("Installed for all users · admin required").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StartupRow<Action: View>: View {
    let item: StartupItem
    let busy: Bool
    @ViewBuilder var action: Action
    @State private var hovering = false
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let appPath = item.appPath, FileManager.default.fileExists(atPath: appPath) {
                        AppIconView(bundlePath: appPath, kind: .application, size: 30)
                    } else {
                        Image(systemName: item.kind == .daemon ? "lock.shield" : "gearshape.2")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                        if let developer = item.developer {
                            Text(developer).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        if !item.isEnabled {
                            Text("Off").font(.caption2.weight(.semibold)).glassChip()
                        } else if item.isRunning {
                            Label("Running", systemImage: "circle.fill").font(.caption2).foregroundStyle(.green)
                        }
                    }
                    Text(item.purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(meta).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                Button { withAnimation(.spring(response: 0.35)) { showDetails.toggle() } } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                    .opacity(hovering || showDetails ? 1 : 0.35)
                    .help("Technical details")
                action
            }
            if showDetails {
                VStack(alignment: .leading, spacing: 3) {
                    detail("Label", item.label)
                    if let plist = item.plistPath { detail("Plist", plist) }
                    if let exe = item.executablePath { detail("Program", exe) }
                    detail("Type", item.kind.title)
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
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.03 : 0)))
        .onHover { hovering = $0 }
    }

    private var meta: String {
        var parts = [item.schedule.text]
        if let lastRun = item.lastRun { parts.append("last ran \(lastRun.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}
