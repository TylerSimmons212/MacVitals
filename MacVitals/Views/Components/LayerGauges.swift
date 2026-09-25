import SwiftUI
import AppKit
import QuartzCore

// Bars and rings drawn with Core Animation layers.
//
// Why (measured on the CPU page): SwiftUI animations are computed *in our process on every
// display frame* (up to 120 fps). With values changing every 2 seconds, something was almost
// always animating, costing ~25% of a core for bars/rings alone. Core Animation runs the same
// glide in the system's render server, so our app does zero per-frame work.

/// A fill bar (horizontal or vertical) that glides to new values via Core Animation.
/// Draw the track behind it in SwiftUI; this only draws the fill.
struct LayerBar: NSViewRepresentable {
    var fraction: Double
    var color: Color
    var axis: Axis = .horizontal
    /// nil = rounded ends (capsule).
    var cornerRadius: CGFloat? = nil
    var duration: CFTimeInterval = 0.5

    func makeNSView(context: Context) -> LayerBarView { LayerBarView() }

    func updateNSView(_ view: LayerBarView, context: Context) {
        view.update(fraction: fraction, color: NSColor(color), axis: axis, cornerRadius: cornerRadius,
                    duration: context.transaction.disablesAnimations ? 0 : duration)
    }
}

final class LayerBarView: NSView {
    private let fill = CAGradientLayer()
    private var fraction = 0.0
    private var color = NSColor.controlAccentColor
    private var axis: Axis = .horizontal
    private var cornerRadius: CGFloat?
    private var hasLaidOut = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func update(fraction: Double, color: NSColor, axis: Axis, cornerRadius: CGFloat?, duration: CFTimeInterval) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.color = color
        self.axis = axis
        self.cornerRadius = cornerRadius
        apply(duration: hasLaidOut ? duration : 0)
    }

    override func layout() {
        super.layout()
        hasLaidOut = true
        apply(duration: 0) // resizing the window shouldn't animate
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(duration: 0) // re-resolve dynamic colors for light/dark
    }

    private func apply(duration: CFTimeInterval) {
        let bounds = self.bounds
        let target: CGRect = axis == .horizontal
            ? CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
            : CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * fraction)
        var colors: [CGColor] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = color.usingColorSpace(.deviceRGB) ?? color
            colors = [base.blended(withFraction: 0.18, of: .white)?.cgColor ?? base.cgColor, base.cgColor]
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setDisableActions(duration == 0)
        fill.frame = target
        fill.cornerRadius = min(cornerRadius ?? .infinity, min(target.width, target.height) / 2,
                                min(bounds.width, bounds.height) / 2)
        fill.colors = colors
        CATransaction.commit()
    }
}

/// A progress ring whose arc glides via Core Animation. Draw the faint track in SwiftUI.
struct LayerRing: NSViewRepresentable {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat
    var duration: CFTimeInterval = 0.6

    func makeNSView(context: Context) -> LayerRingView { LayerRingView() }

    func updateNSView(_ view: LayerRingView, context: Context) {
        view.update(fraction: fraction, color: NSColor(color), lineWidth: lineWidth,
                    duration: context.transaction.disablesAnimations ? 0 : duration)
    }
}

final class LayerRingView: NSView {
    private let arc = CAShapeLayer()
    private var fraction = 0.0
    private var color = NSColor.controlAccentColor
    private var lineWidth: CGFloat = 10
    private var hasLaidOut = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
        layer?.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(fraction: Double, color: NSColor, lineWidth: CGFloat, duration: CFTimeInterval) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.color = color
        self.lineWidth = lineWidth
        apply(duration: hasLaidOut ? duration : 0)
    }

    override func layout() {
        super.layout()
        hasLaidOut = true
        apply(duration: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(duration: 0)
    }

    private func apply(duration: CFTimeInterval) {
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // Start at 12 o'clock and go clockwise (layer y-axis points up).
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        var stroke: CGColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { stroke = self.color.cgColor }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.path = path
        arc.lineWidth = lineWidth
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setDisableActions(duration == 0)
        arc.strokeEnd = fraction
        arc.strokeColor = stroke
        CATransaction.commit()
    }
}

/// A stacked bar (e.g. memory composition) whose segments glide via Core Animation.
struct LayerSegments: NSViewRepresentable {
    struct Segment: Equatable {
        let id: String
        let start: Double
        let end: Double
        let color: Color
    }

    var segments: [Segment]
    var gap: CGFloat = 2
    var duration: CFTimeInterval = 0.5

    func makeNSView(context: Context) -> LayerSegmentsView { LayerSegmentsView() }

    func updateNSView(_ view: LayerSegmentsView, context: Context) {
        view.update(segments.map { ($0.id, $0.start, $0.end, NSColor($0.color)) }, gap: gap,
                    duration: context.transaction.disablesAnimations ? 0 : duration)
    }
}

final class LayerSegmentsView: NSView {
    private var layersByID: [String: CAGradientLayer] = [:]
    private var segments: [(id: String, start: Double, end: Double, color: NSColor)] = []
    private var gap: CGFloat = 2
    private var hasLaidOut = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ segments: [(String, Double, Double, NSColor)], gap: CGFloat, duration: CFTimeInterval) {
        self.segments = segments.map { (id: $0.0, start: $0.1, end: $0.2, color: $0.3) }
        self.gap = gap
        apply(duration: hasLaidOut ? duration : 0)
    }

    override func layout() {
        super.layout()
        hasLaidOut = true
        apply(duration: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(duration: 0)
    }

    private func apply(duration: CFTimeInterval) {
        guard let root = layer else { return }
        let ids = Set(segments.map(\.id))
        for (id, stale) in layersByID where !ids.contains(id) {
            stale.removeFromSuperlayer()
            layersByID[id] = nil
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setDisableActions(duration == 0)
        for segment in segments {
            let sublayer: CAGradientLayer
            if let existing = layersByID[segment.id] {
                sublayer = existing
            } else {
                sublayer = CAGradientLayer()
                sublayer.startPoint = CGPoint(x: 0.5, y: 1)
                sublayer.endPoint = CGPoint(x: 0.5, y: 0)
                root.addSublayer(sublayer)
                layersByID[segment.id] = sublayer
            }
            let x0 = bounds.width * min(1, max(0, segment.start))
            let x1 = max(x0, bounds.width * min(1, max(0, segment.end)) - gap)
            sublayer.frame = CGRect(x: x0, y: 0, width: x1 - x0, height: bounds.height)
            sublayer.cornerRadius = min(3, (x1 - x0) / 2)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let base = segment.color.usingColorSpace(.deviceRGB) ?? segment.color
                sublayer.colors = [base.blended(withFraction: 0.18, of: .white)?.cgColor ?? base.cgColor, base.cgColor]
            }
        }
        CATransaction.commit()
    }
}

/// Ring with a faint track (SwiftUI, static) and a Core Animation arc.
struct GaugeRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            LayerRing(fraction: fraction, color: color, lineWidth: lineWidth)
        }
    }
}
