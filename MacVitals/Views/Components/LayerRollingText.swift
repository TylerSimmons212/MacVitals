import SwiftUI
import AppKit
import QuartzCore

// Rolling digits drawn with Core Animation.
//
// Why: SwiftUI's `.contentTransition(.numericText())` is recomputed in our process on every
// display frame while it plays. On a number that changes every 2 seconds that measured
// +10–17% of a core per page. Here each character is its own layer, and only the characters
// that changed slide out/in, animated by the render server, so our process does no per-frame work.

/// A number that rolls its changed digits (up when the value rises, down when it falls).
/// Sits on the text baseline like `Text`, so it lines up next to units ("%", "GB").
struct RollingText: View {
    let text: String
    var size: CGFloat
    var weight: NSFont.Weight = .bold
    var rounded = true
    var color: Color? = nil
    var alignment: HorizontalAlignment = .center
    var minimumScale: CGFloat = 0.6

    init(_ text: String, size: CGFloat, weight: NSFont.Weight = .bold, rounded: Bool = true,
         color: Color? = nil, alignment: HorizontalAlignment = .center, minimumScale: CGFloat = 0.6) {
        self.text = text
        self.size = size
        self.weight = weight
        self.rounded = rounded
        self.color = color
        self.alignment = alignment
        self.minimumScale = minimumScale
    }

    var body: some View {
        let font = RollingTextView.font(size: size, weight: weight, rounded: rounded)
        let lineHeight = RollingTextView.lineHeight(font)
        let baseline: (ViewDimensions) -> CGFloat = { d in d.height + font.descender * (d.height / lineHeight) }
        RollingTextLayer(text: text, size: size, weight: weight, rounded: rounded, color: color,
                         alignment: alignment, minimumScale: minimumScale)
            .alignmentGuide(.firstTextBaseline, computeValue: baseline)
            .alignmentGuide(.lastTextBaseline, computeValue: baseline)
            .accessibilityElement()
            .accessibilityLabel(text)
    }
}

private struct RollingTextLayer: NSViewRepresentable {
    let text: String
    var size: CGFloat
    var weight: NSFont.Weight = .bold
    var rounded = true
    var color: Color? = nil
    var alignment: HorizontalAlignment = .center
    /// Shrinks to fit when the proposed width is narrower (like `.minimumScaleFactor`).
    var minimumScale: CGFloat = 0.6

    func makeNSView(context: Context) -> RollingTextView { RollingTextView() }

    func updateNSView(_ view: RollingTextView, context: Context) {
        let animated = !context.transaction.disablesAnimations && !context.environment.accessibilityReduceMotion
        view.update(text: text,
                    font: RollingTextView.font(size: size, weight: weight, rounded: rounded),
                    color: color.map { NSColor($0) } ?? .labelColor,
                    alignment: alignment,
                    animated: animated)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingTextView, context: Context) -> CGSize? {
        let font = RollingTextView.font(size: size, weight: weight, rounded: rounded)
        let natural = RollingTextView.naturalSize(text, font: font)
        guard let width = proposal.width, width.isFinite, width < natural.width else { return natural }
        let scale = max(minimumScale, width / max(natural.width, 1))
        return CGSize(width: ceil(natural.width * scale), height: ceil(natural.height * scale))
    }
}

final class RollingTextView: NSView {
    private let container = CALayer()
    /// Characters and their layers, indexed from the right so "9%" → "10%" keeps the "%".
    private var chars: [Character] = []
    private var layersFromRight: [CATextLayer] = []
    private var incoming: Set<ObjectIdentifier> = []
    private var outgoing: [CATextLayer] = []
    private var rollsUp = true
    private var pendingAnimation = false

    private var font = NSFont.systemFont(ofSize: 13)
    private var color = NSColor.labelColor
    private var alignment: HorizontalAlignment = .center
    private var hasLaidOut = false

    private let duration: CFTimeInterval = 0.45

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        container.anchorPoint = .zero
        layer?.addSublayer(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Fonts & metrics

    static func font(size: CGFloat, weight: NSFont.Weight, rounded: Bool) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if rounded, let roundedDescriptor = descriptor.withDesign(.rounded) { descriptor = roundedDescriptor }
        // Monospaced digits (kNumberSpacingType = 6, kMonospacedNumbersSelector = 0) so columns don't jitter.
        descriptor = descriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: 6,
            NSFontDescriptor.FeatureKey.selectorIdentifier: 0,
        ]]])
        return NSFont(descriptor: descriptor, size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }

    static func width(of character: Character, font: NSFont) -> CGFloat {
        (String(character) as NSString).size(withAttributes: [.font: font]).width
    }

    static func naturalSize(_ text: String, font: NSFont) -> CGSize {
        CGSize(width: ceil(text.reduce(0) { $0 + width(of: $1, font: font) }), height: lineHeight(font))
    }

    // MARK: Updates

    func update(text: String, font: NSFont, color: NSColor, alignment: HorizontalAlignment, animated: Bool) {
        let newChars = Array(text.reversed())
        let styleChanged = font != self.font || color != self.color
        self.font = font
        self.color = color
        self.alignment = alignment

        if styleChanged {
            layersFromRight.forEach(style)
        }
        guard newChars != chars else { return }

        let shouldAnimate = animated && hasLaidOut && !chars.isEmpty
        rollsUp = Self.numericValue(String(newChars.reversed())) ?? 0 >= Self.numericValue(String(chars.reversed())) ?? 0

        var newLayers: [CATextLayer] = []
        for index in 0..<newChars.count {
            if index < chars.count, chars[index] == newChars[index] {
                newLayers.append(layersFromRight[index])
                continue
            }
            let fresh = makeLayer(newChars[index])
            if shouldAnimate {
                fresh.opacity = 0 // revealed by the roll-in in layout()
                incoming.insert(ObjectIdentifier(fresh))
            }
            newLayers.append(fresh)
        }
        for index in 0..<chars.count where index >= newChars.count || chars[index] != newChars[index] {
            let old = layersFromRight[index]
            if shouldAnimate, !incoming.contains(ObjectIdentifier(old)) {
                outgoing.append(old)
            } else {
                incoming.remove(ObjectIdentifier(old))
                old.removeFromSuperlayer()
            }
        }
        chars = newChars
        layersFromRight = newLayers
        pendingAnimation = pendingAnimation || shouldAnimate
        needsLayout = true
    }

    private func makeLayer(_ character: Character) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.string = String(character)
        textLayer.alignmentMode = .center
        textLayer.isWrapped = false
        textLayer.anchorPoint = .zero
        style(textLayer)
        container.addSublayer(textLayer)
        return textLayer
    }

    private func style(_ textLayer: CATextLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            textLayer.foregroundColor = self.color.cgColor
        }
        CATransaction.commit()
    }

    private static func numericValue(_ text: String) -> Double? {
        Double(text.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        hasLaidOut = true
        let animate = pendingAnimation
        pendingAnimation = false

        let natural = Self.naturalSize(String(chars.reversed()), font: font)
        let scale = natural.width > 0 ? min(1, bounds.width / natural.width) : 1
        let scaledWidth = natural.width * scale
        let x: CGFloat = switch alignment {
        case .leading: 0
        case .trailing: bounds.width - scaledWidth
        default: (bounds.width - scaledWidth) / 2
        }
        let height = Self.lineHeight(font)
        let travel = height * 0.7

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(origin: .zero, size: natural)
        container.position = CGPoint(x: x, y: (bounds.height - natural.height * scale) / 2)
        container.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()

        // Position left-to-right. Unchanged digits glide if the width changed; new ones roll in.
        var cursor: CGFloat = 0
        var slots: [(layer: CATextLayer, frame: CGRect)] = []
        for (index, character) in chars.reversed().enumerated() {
            let width = Self.width(of: character, font: font)
            slots.append((layersFromRight[chars.count - 1 - index], CGRect(x: cursor, y: 0, width: width, height: height)))
            cursor += width
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animate ? duration : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        CATransaction.setDisableActions(!animate)
        for slot in slots {
            let id = ObjectIdentifier(slot.layer)
            if incoming.contains(id) {
                // Start just outside the slot, then roll into place.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                slot.layer.bounds = CGRect(origin: .zero, size: slot.frame.size)
                slot.layer.position = CGPoint(x: slot.frame.minX, y: rollsUp ? -travel : travel)
                CATransaction.commit()
                slot.layer.position = slot.frame.origin
                slot.layer.opacity = 1
            } else {
                slot.layer.bounds = CGRect(origin: .zero, size: slot.frame.size)
                slot.layer.position = slot.frame.origin
                slot.layer.opacity = 1
            }
        }
        incoming.removeAll()

        let leaving = outgoing
        outgoing.removeAll()
        CATransaction.setCompletionBlock { leaving.forEach { $0.removeFromSuperlayer() } }
        for old in leaving {
            old.position = CGPoint(x: old.position.x, y: rollsUp ? travel : -travel)
            old.opacity = 0
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layersFromRight.forEach(style)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layersFromRight.forEach(style)
    }
}
