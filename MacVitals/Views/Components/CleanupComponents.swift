import SwiftUI

/// Radar-style scanner: a rotating sweep with expanding pulse rings while scanning,
/// resolving into a progress ring and a sparkle glyph.
struct ScanOrb: View {
    let scanning: Bool
    let progress: Double
    let animated: Bool

    var body: some View {
        ZStack {
            // Radar sweep + ripples run in Core Animation: smooth at the display's frame rate,
            // and no per-frame work in our process (the old TimelineView redrew 30×/s).
            ScanSweep(scanning: scanning, animated: animated, color: NSColor(Theme.cleanup))
                .padding(10)
            LayerRing(fraction: progress, color: Theme.cleanup, lineWidth: 5)
                .padding(4)
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Theme.cleanup.gradient)
                .symbolEffect(.variableColor.iterative.reversing, isActive: scanning && animated)
                .symbolEffect(.bounce, value: scanning)
        }
        .glassEffect(.regular.tint(Theme.cleanup.opacity(0.15)), in: .circle)
    }
}

/// A slow radar sweep (one turn every 2.4 s) with ripples expanding outward while scanning.
/// At rest: a faint, still sweep. Reduce Motion / ambient motion off: still, no ripples.
private struct ScanSweep: NSViewRepresentable {
    let scanning: Bool
    let animated: Bool
    let color: NSColor

    func makeNSView(context: Context) -> ScanSweepView { ScanSweepView() }

    func updateNSView(_ view: ScanSweepView, context: Context) {
        view.update(scanning: scanning, animated: animated, color: color)
    }
}

final class ScanSweepView: NSView {
    private let sweep = CAGradientLayer()
    private let sweepMask = CAShapeLayer()
    private var ripples: [CAShapeLayer] = []
    private var scanning = false
    private var animated = false
    private var color = NSColor.systemMint

    static let turnDuration: CFTimeInterval = 2.4
    static let rippleDuration: CFTimeInterval = 2.4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for _ in 0..<3 {
            let ripple = CAShapeLayer()
            ripple.fillColor = nil
            ripple.lineWidth = 1.5
            ripple.opacity = 0
            layer?.addSublayer(ripple)
            ripples.append(ripple)
        }
        sweep.type = .conic
        sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweep.endPoint = CGPoint(x: 0.5, y: 1)
        sweep.mask = sweepMask
        layer?.addSublayer(sweep)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(scanning: Bool, animated: Bool, color: NSColor) {
        let changed = scanning != self.scanning || animated != self.animated || color != self.color
        self.scanning = scanning
        self.animated = animated
        self.color = color
        if changed { apply() }
    }

    override func layout() {
        super.layout()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        let bounds = self.bounds
        guard bounds.width > 0 else { return }
        let side = min(bounds.width, bounds.height)
        let square = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        var colors: [CGColor] = []
        var stroke = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = [self.color.withAlphaComponent(0).cgColor, self.color.withAlphaComponent(self.scanning ? 0.55 : 0.15).cgColor]
            stroke = self.color.withAlphaComponent(0.5).cgColor
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.bounds = CGRect(origin: .zero, size: square.size)
        sweep.position = CGPoint(x: square.midX, y: square.midY)
        sweep.colors = colors
        sweepMask.frame = sweep.bounds
        sweepMask.path = CGPath(ellipseIn: sweep.bounds, transform: nil)
        // Ripples start at the orb's inner ring and fade out just past its edge.
        for ripple in ripples {
            ripple.bounds = CGRect(origin: .zero, size: square.size)
            ripple.position = CGPoint(x: square.midX, y: square.midY)
            ripple.path = CGPath(ellipseIn: ripple.bounds, transform: nil)
            ripple.strokeColor = stroke
        }
        CATransaction.commit()

        let moving = scanning && animated
        if moving, sweep.animation(forKey: "turn") == nil {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi // clockwise
            turn.duration = Self.turnDuration
            turn.repeatCount = .infinity
            sweep.add(turn, forKey: "turn")

            let now = CACurrentMediaTime()
            for (index, ripple) in ripples.enumerated() {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.6
                scale.toValue = 1.25
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.9
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                group.duration = Self.rippleDuration
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.repeatCount = .infinity
                group.beginTime = now + Self.rippleDuration * Double(index) / Double(ripples.count)
                group.fillMode = .backwards
                ripple.add(group, forKey: "ripple")
            }
        } else if !moving {
            sweep.removeAnimation(forKey: "turn")
            ripples.forEach { $0.removeAnimation(forKey: "ripple") }
        }
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
