import Foundation
import CoreGraphics

/// Geometry for the Space Lens ring chart: the folder you're looking at sits in the middle,
/// its contents form the first ring, their contents the next, and so on. Each slice's angle is
/// its share of the folder. Pure math, so hit-testing and layout are unit-tested.
enum Sunburst {
    struct Segment: Identifiable {
        let node: SpaceNode
        /// 1 = first ring around the center.
        let depth: Int
        /// Fractions of a full turn, 0…1, clockwise from 12 o'clock.
        let start: Double
        let end: Double
        /// Index of the first-ring ancestor, so a whole branch shares a color family.
        let branch: Int

        var id: ObjectIdentifier { node.id }
        var span: Double { end - start }
        var mid: Double { (start + end) / 2 }
    }

    struct Geometry {
        let radius: CGFloat
        let rings: Int

        /// The center disc (folder name and size) takes the inner part.
        var hole: CGFloat { radius * 0.36 }
        var ringWidth: CGFloat { (radius - hole) / CGFloat(rings) }

        func inner(_ depth: Int) -> CGFloat { hole + ringWidth * CGFloat(depth - 1) }
        func outer(_ depth: Int) -> CGFloat { hole + ringWidth * CGFloat(depth) }
    }

    /// Slices smaller than this share of a full turn aren't drawn (they'd be hairlines);
    /// they're still in the list beside the chart.
    static let minimumSpan = 0.0025

    static func layout(_ root: SpaceNode, rings: Int = 3) -> [Segment] {
        guard root.size > 0 else { return [] }
        var segments: [Segment] = []
        func place(_ node: SpaceNode, from start: Double, span: Double, depth: Int, branch: Int) {
            guard depth <= rings, node.size > 0 else { return }
            var cursor = start
            for (index, child) in node.children.enumerated() where child.size > 0 {
                let childSpan = span * Double(child.size) / Double(node.size)
                let childBranch = depth == 1 ? index : branch
                if childSpan >= minimumSpan {
                    segments.append(Segment(node: child, depth: depth, start: cursor, end: cursor + childSpan, branch: childBranch))
                    if child.isFolder { place(child, from: cursor, span: childSpan, depth: depth + 1, branch: childBranch) }
                }
                cursor += childSpan
            }
        }
        place(root, from: 0, span: 1, depth: 1, branch: 0)
        return segments
    }

    /// Which slice is under a point (relative to the chart's center, y down). nil = the center
    /// disc or empty space.
    static func hit(_ point: CGPoint, in segments: [Segment], geometry: Geometry) -> Segment? {
        let distance = hypot(point.x, point.y)
        guard distance > geometry.hole, distance <= geometry.radius else { return nil }
        let depth = Int((distance - geometry.hole) / geometry.ringWidth) + 1
        let fraction = turnFraction(point)
        return segments.first { $0.depth == depth && fraction >= $0.start && fraction < $0.end }
    }

    /// Clockwise fraction of a turn from 12 o'clock, for a point relative to center (y down).
    static func turnFraction(_ point: CGPoint) -> Double {
        var angle = atan2(Double(point.x), Double(-point.y)) // 0 at top, clockwise positive
        if angle < 0 { angle += 2 * .pi }
        return angle / (2 * .pi)
    }
}
