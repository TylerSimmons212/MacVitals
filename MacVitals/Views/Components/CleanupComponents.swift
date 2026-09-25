import SwiftUI

/// Radar-style scanner: a rotating sweep with expanding pulse rings while scanning,
/// resolving into a progress ring and a sparkle glyph.
struct ScanOrb: View {
    let scanning: Bool
    let progress: Double
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(scanning && animated))) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                if scanning {
                    ForEach(0..<3) { i in
                        let phase = (t * 0.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(Theme.cleanup.opacity(0.5 * (1 - phase)), lineWidth: 1.5)
                            .scaleEffect(0.55 + phase * 0.55)
                    }
                }
                Circle()
                    .fill(AngularGradient(colors: [Theme.cleanup.opacity(0), Theme.cleanup.opacity(scanning ? 0.55 : 0.15)], center: .center))
                    .rotationEffect(.degrees(scanning ? t * 220 : 0))
                    .mask(Circle().padding(10))
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.cleanup.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(4)
                    .animation(.spring(response: 0.6), value: progress)
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Theme.cleanup.gradient)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: scanning && animated)
                    .symbolEffect(.bounce, value: scanning)
            }
        }
        .glassEffect(.regular.tint(Theme.cleanup.opacity(0.15)), in: .circle)
    }
}

struct TierPill: View {
    let tier: SafetyTier

    var body: some View {
        Text(tier.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.tier(tier).opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.tier(tier))
            .help(tier.explanation)
    }
}

/// Shown after a cleanup: what happened, plus Empty now (actually free the space) and Put back.
struct CleanupResultBanner: View {
    let record: CleanupRecord
    @Environment(CleanupEngine.self) private var engine
    @Environment(Permissions.self) private var permissions
    @State private var celebrate = false
    @State private var working = false

    private var fixable: [RemovalBlocker] {
        [.appManagement, .fullDiskAccess, .admin].filter { !record.failed($0).isEmpty }
    }

    var body: some View {
        let inTrash = record.movedToTrash
        let restorable = !record.restorable.isEmpty
        let nothingRemoved = record.entries.isEmpty
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: nothingRemoved ? "hand.raised.fill" : record.failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(nothingRemoved || !record.failures.isEmpty ? .orange : .green)
                    .symbolEffect(.bounce.up.byLayer, value: celebrate)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.headline)
                    Text(subheadline(inTrash: inTrash))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if restorable {
                    Button("Put Back") {
                        working = true
                        Task { await engine.putBack(record); working = false }
                    }
                    .buttonStyle(.glass)
                    .pointerStyle(.link)
                    .help("Move everything back to where it was")
                }
                if inTrash > 0 && restorable {
                    Button("Empty Now") {
                        working = true
                        Task { await engine.finalize(record); working = false }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.cleanup)
                    .pointerStyle(.link)
                    .help("Permanently delete just what Mac Vitals moved to the Trash, so the space is freed now. The rest of your Trash isn't touched.")
                }
                Button("Done") { withAnimation(.smooth) { engine.dismissResult() } }
                    .buttonStyle(.glass)
                    .pointerStyle(.link)
            }
            ForEach(fixable, id: \.self) { blocker in
                blockerRow(blocker)
            }
        }
        .cardStyle(padding: 16, tint: nothingRemoved ? .orange : .green)
        .onAppear { celebrate.toggle() }
        .animation(.smooth, value: record.failedItems ?? [])
    }

    /// One line per fixable reason: what happened, in plain words, and the one button that fixes it.
    private func blockerRow(_ blocker: RemovalBlocker) -> some View {
        let items = record.failed(blocker)
        let names = ListFormatter.localizedString(byJoining: items.prefix(3).map(\.name)) + (items.count > 3 ? " and \(items.count - 3) more" : "")
        let (icon, message, action): (String, String, String) = switch blocker {
        case .appManagement:
            ("square.grid.3x3.fill", "macOS stopped Mac Vitals from deleting \(names). Allow App Management once, and it'll finish.", "Allow & Finish")
        case .fullDiskAccess:
            ("lock.fill", "\(names) \(items.count == 1 ? "is" : "are") in a folder macOS protects. Allow Full Disk Access to finish.", "Allow & Finish")
        case .admin:
            ("person.badge.key.fill", "\(names) \(items.count == 1 ? "was" : "were") installed for all users. Finder can move \(items.count == 1 ? "it" : "them") to the Trash after you enter your password.", "Remove with Finder…")
        case .other:
            ("questionmark.circle", "", "")
        }
        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange).frame(width: 20)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action) { fix(blocker) }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .controlSize(.small)
                .pointerStyle(.link)
                .disabled(working)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
    }

    private func fix(_ blocker: RemovalBlocker) {
        let retry = { @MainActor in
            working = true
            Task { await engine.resolve(record, blocker); working = false }
        }
        switch blocker {
        case .appManagement: permissions.request(.appManagement) { retry() }
        case .fullDiskAccess: permissions.request(.fullDiskAccess) { retry() }
        case .admin: permissions.request(.finder) { retry() }
        case .other: break
        }
    }

    private var headline: String {
        if record.entries.isEmpty { return "Nothing was removed yet" }
        if record.movedToTrash > 0 { return "Moved \(Fmt.bytes(record.movedToTrash)) to the Trash" }
        return "Freed \(Fmt.bytes(record.deletedPermanently))"
    }

    private func subheadline(inTrash: Int64) -> String {
        var parts: [String] = []
        if record.entries.isEmpty {
            return fixable.isEmpty ? "\(record.failures.count) item\(record.failures.count == 1 ? " is" : "s are") in use or protected by macOS." : "macOS needs your OK first. Nothing has been changed."
        }
        parts.append("\(record.entries.count) item\(record.entries.count == 1 ? "" : "s") cleaned.")
        if inTrash > 0 { parts.append("The space is freed when the Trash is emptied. Changed your mind? Put Back restores everything.") }
        if record.deletedPermanently > 0 && record.movedToTrash > 0 { parts.append("\(Fmt.bytes(record.deletedPermanently)) was deleted permanently.") }
        let unfixable = record.failedItems.map { $0.filter { $0.blocker == .other }.count } ?? record.failures.count
        if unfixable > 0 { parts.append("\(unfixable) couldn't be removed (in use or protected by macOS).") }
        return parts.joined(separator: " ")
    }
}
