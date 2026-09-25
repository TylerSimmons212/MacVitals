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
                    .rollingNumber(value)
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
        .animation(.smooth(duration: 0.5), value: values)
    }

    private func bar(_ value: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2.5).fill(.quaternary)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(value > 85 ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(tint.gradient))
                    .frame(height: max(2, proxy.size.height * min(1, value / 100)))
            }
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
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: proxy.size.width * min(1, max(0, usedFraction)))
                    ForEach([0.85, 0.95], id: \.self) { mark in
                        Rectangle()
                            .fill(.primary.opacity(0.25))
                            .frame(width: 1.5, height: proxy.size.height + 4)
                            .offset(x: proxy.size.width * mark)
                    }
                }
            }
            .frame(height: 12)
            HStack {
                Text("\(Fmt.percent(usedFraction * 100)) used")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .animation(.smooth(duration: 0.8), value: usedFraction)
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
        .animation(.smooth(duration: 0.4), value: level)
    }
}

/// Battery: a battery-shaped fill with a bolt while charging.
struct BatteryGlyph: View {
    let percent: Double
    let charging: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.secondary.opacity(0.5), lineWidth: 1.5)
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(fill.gradient)
                        .padding(3)
                        .frame(width: max(10, proxy.size.width * min(1, percent / 100)))
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .frame(maxWidth: .infinity)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.secondary.opacity(0.5))
                .frame(width: 3, height: 12)
        }
        .frame(height: 26)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .animation(.smooth(duration: 0.8), value: percent)
        .animation(.spring, value: charging)
    }

    private var fill: Color {
        percent < 20 ? .red : percent < 35 ? .orange : tint
    }
}
