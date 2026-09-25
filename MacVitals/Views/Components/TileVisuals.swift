import SwiftUI

// Purpose-built glyphs for the overview tiles. Each one shows the *shape* of its metric
// at a glance (how load spreads across cores, what memory is made of, how full the disk is)
// instead of a generic moving line. Time-series history lives on the detail pages.
//
// All of these animate only when their value changes (value-scoped animations), so they
// cost nothing between samples.

/// Tile with a headline value, caption and a metric-specific visual. Stretches to fill its row.
struct MetricTile<Visual: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let caption: String
    var action: () -> Void
    @ViewBuilder var visual: Visual

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(title, systemImage: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .offset(x: hovering ? 2 : 0)
                }
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                visual
                    .frame(height: 34)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .cardStyle(padding: 14, tint: tint, interactive: true, fillHeight: true)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}

/// CPU: one bar per core, so you can see whether load is spread out or pinned to one core.
struct CoreStrip: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            if values.isEmpty {
                ForEach(0..<8, id: \.self) { _ in bar(0) }
            } else {
                ForEach(values.indices, id: \.self) { index in
                    bar(values[index])
                }
            }
        }

    }

    private func bar(_ value: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5).fill(.quaternary)
            LayerBar(fraction: max(0.03, value / 100), color: value > 85 ? .red : tint, axis: .vertical, cornerRadius: 2.5)
        }
    }
}

/// Memory: what RAM is made of. Wired and compressed are the parts that signal trouble.
struct MemoryComposition: View {
    let memory: MemorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SegmentedBar(segments: segments, height: 12)
            HStack(spacing: 10) {
                ForEach(segments.prefix(3)) { segment in
                    HStack(spacing: 4) {
                        Circle().fill(segment.color).frame(width: 6, height: 6)
                        Text(segment.label)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var segments: [SegmentedBar.Segment] {
        [
            .init(label: "App", value: Double(memory.app), color: Theme.memory),
            .init(label: "Wired", value: Double(memory.wired), color: .orange),
            .init(label: "Compressed", value: Double(memory.compressed), color: .pink),
            .init(label: "Cached", value: Double(memory.cached), color: .blue.opacity(0.5)),
            .init(label: "Free", value: Double(memory.free), color: .gray.opacity(0.3)),
        ]
    }
}

/// Disk: how full the startup disk is, with tick marks at the 85% / 95% danger lines.
struct CapacityGauge: View {
    let usedFraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Capsule().fill(.quaternary)
                LayerBar(fraction: usedFraction, color: color)
            }
            .frame(height: 12)
            .overlay {
                // Static tick marks at the 85% / 95% danger lines (not animated, so no layout churn).
                GeometryReader { proxy in
                    ForEach([0.85, 0.95], id: \.self) { mark in
                        Rectangle()
                            .fill(.primary.opacity(0.25))
                            .frame(width: 1.5, height: proxy.size.height + 4)
                            .offset(x: proxy.size.width * mark, y: -2)
                    }
                }
            }
            HStack {
                Text("\(Fmt.percent(usedFraction * 100)) used")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

    }

    private var color: Color {
        switch usedFraction {
        case ..<0.85: tint
        case 0.85..<0.95: .orange
        default: .red
        }
    }
}

/// Network: download and upload as level meters on a log scale (1 KB/s … 100 MB/s),
/// so both a trickle and a big download read sensibly.
struct NetworkLevels: View {
    let download: Double
    let upload: Double

    var body: some View {
        VStack(spacing: 6) {
            row(symbol: "arrow.down", rate: download, tint: Theme.network)
            row(symbol: "arrow.up", rate: upload, tint: Theme.upload)
        }
    }

    private func row(symbol: String, rate: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 10)
            SegmentMeter(level: Self.level(for: rate), tint: tint)
        }
    }

    static func level(for bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 1_000 else { return 0 }
        let decades = log10(bytesPerSecond / 1_000) // 0 at 1 KB/s, 5 at 100 MB/s
        return min(1, decades / 5)
    }
}

/// Row of discrete segments that light up with the level (like an audio meter).
struct SegmentMeter: View {
    let level: Double
    let tint: Color
    var segments = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let lit = Double(index) < level * Double(segments)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(lit ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary))
            }
        }
        .frame(height: 10)
        // Snaps like an audio meter; animating it every refresh kept SwiftUI busy for nothing.
    }
}

/// Battery: a battery-shaped fill with a bolt while charging.
struct BatteryGlyph: View {
    let percent: Double
    let charging: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.secondary.opacity(0.5), lineWidth: 1.5)
                LayerBar(fraction: max(0.08, percent / 100), color: fill, cornerRadius: 3.5)
                    .padding(3)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.secondary.opacity(0.5))
                .frame(width: 3, height: 12)
        }
        .frame(height: 26)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .animation(.spring, value: charging)
    }

    private var fill: Color {
        percent < 20 ? .red : percent < 35 ? .orange : tint
    }
}
