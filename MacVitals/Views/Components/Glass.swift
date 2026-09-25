import SwiftUI

// MARK: - Motion preferences

/// Central switch for decorative motion. Honors Reduce Motion, the user's setting,
/// and pauses whenever the window isn't active so the app stays near-zero CPU in the background.
struct MotionPolicy {
    let enabled: Bool

    static func resolve(reduceMotion: Bool, userEnabled: Bool, active: Bool) -> MotionPolicy {
        MotionPolicy(enabled: !reduceMotion && userEnabled && active)
    }
}

extension EnvironmentValues {
    /// Whether decorative motion (backdrop transitions, scanning effects) should run right now.
    @Entry var motionEnabled: Bool = true
}

// MARK: - Ambient backdrop

/// Mesh gradient that sits behind all glass. Its hue follows the Mac's health, so the
/// whole window warms toward orange/red when something is wrong.
///
/// Motion is event-driven, never continuous: it "breathes in" when the window appears,
/// reshapes when you change sections, and glides to a new tint when health changes.
/// Continuous drift forced every glass surface to re-sample each frame (~30% CPU).
struct AmbientBackground: View {
    let tint: Color
    /// Changing this reshapes the mesh (e.g. the selected section's index).
    var arrangement: Int = 0
    var animated = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var settled = false

    var body: some View {
        MeshGradient(width: 3, height: 3, points: points, colors: colors)
            .overlay(colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.25))
            .ignoresSafeArea()
            .animation(animated ? .smooth(duration: 1.6) : nil, value: arrangement)
            .animation(.smooth(duration: 2), value: tint)
            .onAppear {
                guard animated else { settled = true; return }
                withAnimation(.smooth(duration: 2.4)) { settled = true }
            }
    }

    private var colors: [Color] {
        let base: Color = colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96)
        let glow = settled ? 1.0 : 0.4
        return [
            tint.opacity(0.55 * glow), base, Theme.cpu.opacity(0.45 * glow),
            base, tint.opacity(0.25 * glow), base,
            Theme.memory.opacity(0.40 * glow), base, tint.opacity(0.45 * glow),
        ]
    }

    private var points: [SIMD2<Float>] {
        guard settled else {
            // Collapsed start state: interior pulled toward a corner, then it blooms outward.
            return [[0, 0], [0.2, 0], [1, 0], [0, 0.2], [0.15, 0.15], [1, 0.3], [0, 1], [0.3, 1], [1, 1]]
        }
        // Deterministic per-arrangement offsets so each section has its own composition.
        let seed = Double(arrangement)
        func shift(_ k: Double, _ amount: Float = 0.14) -> Float { Float(sin(seed * 1.7 + k)) * amount }
        return [
            [0, 0], [0.5 + shift(0), 0], [1, 0],
            [0, 0.5 + shift(1)], [0.5 + shift(2), 0.5 + shift(3, 0.18)], [1, 0.5 + shift(4)],
            [0, 1], [0.5 + shift(5), 1], [1, 1],
        ]
    }
}

// MARK: - Glass surfaces

extension View {
    /// Standard Liquid Glass panel used for every card.
    func glassCard(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false,
                   padding: CGFloat = 16, fillHeight: Bool = false) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.12)) }
        if interactive { glass = glass.interactive() }
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
    }

    /// Small glass capsule for badges and chips.
    func glassChip(tint: Color? = nil) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.25)) }
        return self
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassEffect(glass, in: .capsule)
    }

    /// Digits roll to their new value. Use only for values that change *rarely* (health score,
    /// counts). Rolling values that change every refresh keeps SwiftUI animating nonstop, which
    /// was a large part of the dashboard's CPU cost.
    func rollingNumber<V: Equatable>(_ value: V) -> some View {
        self
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.45), value: value)
    }

    /// Staggered entrance: rises, sharpens and fades in. Plays once per appearance.
    func entrance(delay: Double = 0) -> some View {
        modifier(EntranceModifier(delay: delay))
    }
}

private struct EntranceModifier: ViewModifier {
    let delay: Double
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible || reduceMotion ? 1 : 0.96)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .blur(radius: visible || reduceMotion ? 0 : 6)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(reduceMotion ? 0 : delay)) {
                    visible = true
                }
            }
    }
}
