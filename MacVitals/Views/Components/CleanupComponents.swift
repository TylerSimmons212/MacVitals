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
    @State private var celebrate = false
    @State private var working = false

    var body: some View {
        let inTrash = record.movedToTrash
        let restorable = !record.restorable.isEmpty
        HStack(spacing: 14) {
            Image(systemName: record.failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(record.failures.isEmpty ? .green : .orange)
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
        .cardStyle(padding: 16, tint: .green)
        .onAppear { celebrate.toggle() }
    }

    private var headline: String {
        if record.movedToTrash > 0 { return "Moved \(Fmt.bytes(record.movedToTrash)) to the Trash" }
        return "Freed \(Fmt.bytes(record.deletedPermanently))"
    }

    private func subheadline(inTrash: Int64) -> String {
        var parts: [String] = []
        parts.append("\(record.entries.count) item\(record.entries.count == 1 ? "" : "s") cleaned.")
        if inTrash > 0 { parts.append("The space is freed when the Trash is emptied. Changed your mind? Put Back restores everything.") }
        if record.deletedPermanently > 0 && record.movedToTrash > 0 { parts.append("\(Fmt.bytes(record.deletedPermanently)) was deleted permanently.") }
        if !record.failures.isEmpty { parts.append("\(record.failures.count) couldn't be removed (in use or protected).") }
        return parts.joined(separator: " ")
    }
}
