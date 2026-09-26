import SwiftUI

/// Maintenance: a few fixes that genuinely help, each listed by the problem it solves, plus the
/// ones left out on purpose and why. Nothing runs until you choose it.
struct MaintenanceView: View {
    @Environment(MaintenanceModel.self) private var model
    @State private var pending: MaintenanceTask?

    var body: some View {
        SectionScroll {
            hero.entrance()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)], spacing: 16) {
                ForEach(MaintenanceTask.all) { task in
                    TaskCard(task: task) {
                        if task.confirm != nil { pending = task } else { Task { await model.run(task) } }
                    }
                }
            }
            .entrance(delay: 0.06)
            leftOutCard.entrance(delay: 0.1)
        }
        .task { if !model.snapshotsChecked { await model.refresh() } }
        .confirmationDialog(pending.map { "\($0.action)?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { task in
            Button(task.action) { Task { await model.run(task) } }
        } message: { task in
            Text(task.confirm ?? "")
        }
    }

    private var hero: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.cleanup.opacity(0.12))
                Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 40)).foregroundStyle(Theme.cleanup.gradient)
            }
            .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                Text("Fixes for common problems").font(.title2.weight(.semibold))
                Text("macOS looks after itself, so there's nothing you need to run on a schedule. These are for when something specific goes wrong: find the problem you're seeing and run its fix.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: Theme.cleanup)
    }

    private var leftOutCard: some View {
        Card("Left out on purpose", systemImage: "hand.raised", tint: .secondary) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Other cleaners offer these. They don't help on a modern Mac, and some make things worse.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(MaintenanceTask.leftOut) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body.weight(.medium))
                            Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct TaskCard: View {
    let task: MaintenanceTask
    let run: () -> Void
    @Environment(MaintenanceModel.self) private var model

    /// Snapshots: only offered when there are some.
    private var unavailableReason: String? {
        guard task.id == .snapshots, model.snapshotsChecked else { return nil }
        return model.snapshots.isEmpty ? "There are no local snapshots on this Mac right now." : nil
    }

    var body: some View {
        let state = model.state(task.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cleanup.opacity(0.15))
                    Image(systemName: task.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.cleanup)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.symptom).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(task.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Label(task.sideEffect, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if task.id == .snapshots, !model.snapshots.isEmpty {
                let oldest = model.snapshots.compactMap(MaintenanceRunner.snapshotDate).min()
                Text("\(model.snapshots.count) local snapshot\(model.snapshots.count == 1 ? "" : "s")\(oldest.map { ", oldest from \($0.formatted(.relative(presentation: .named)))" } ?? "").")
                    .font(.caption.weight(.medium))
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                statusLine(state)
                Spacer(minLength: 8)
                if state == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: run) {
                        Label(task.action, systemImage: task.needsPassword ? "lock.fill" : "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.cleanup)
                    .controlSize(.small)
                    .pointerStyle(.link)
                    .disabled(unavailableReason != nil)
                    .help(task.needsPassword ? "macOS will ask for your password on behalf of Mac Vitals" : task.duration)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardStyle(padding: 16, fillHeight: true)
    }

    @ViewBuilder
    private func statusLine(_ state: MaintenanceModel.State) -> some View {
        switch state {
        case .running:
            Text(task.id == .spotlight ? "Starting…" : "Working…").font(.caption).foregroundStyle(.secondary)
        case .done(let date):
            Label(task.id == .spotlight ? "Rebuilding in the background" : "Done \(date.formatted(.relative(presentation: .named)))",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .idle:
            if let reason = unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    Text(task.duration)
                    if task.needsPassword { Text("· needs your password") }
                    if let last = model.lastRun(task.id) { Text("· last run \(last.formatted(.relative(presentation: .named)))") }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
