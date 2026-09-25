import SwiftUI
import Charts

/// History chart with axes and a legend. Supports multiple series, stacking, gaps in data
/// (drawn as breaks), and an optional dashed reference line (e.g. "typical").
struct HistoryChart: View {
    struct Series {
        let name: String
        let color: Color
    }

    struct Reference {
        let label: String
        let value: Double
    }

    let points: [ChartPoint]
    let series: [Series]
    var range: HistoryRange = .hour
    var yMax: Double? = nil
    var stacked = false
    var reference: Reference? = nil
    var format: (Double) -> String = { Fmt.percent($0) }

    /// Stacked bands, computed explicitly so gaps break cleanly.
    private struct Band: Identifiable {
        let date: Date
        let start: Double
        let end: Double
        let series: String
        let segmentKey: String
        var id: String { "\(series)|\(date.timeIntervalSinceReferenceDate)" }
    }

    var body: some View {
        let now = Date()
        return Chart {
            if stacked {
                ForEach(bands) { band in
                    AreaMark(
                        x: .value("Time", band.date),
                        yStart: .value("Start", band.start),
                        yEnd: .value("End", band.end),
                        series: .value("Segment", band.segmentKey)
                    )
                    .foregroundStyle(by: .value("Series", band.series))
                    .interpolationMethod(.monotone)
                }
            } else {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value),
                        series: .value("Segment", point.segmentKey),
                        stacking: .unstacked
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .opacity(0.18)
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value),
                        series: .value("Segment", point.segmentKey)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
            }
            if let reference, !points.isEmpty {
                RuleMark(y: .value(reference.label, reference.value))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("\(reference.label) \(format(reference.value))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                    }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        // Always show the whole range, so partial history reads as partial.
        .chartXScale(domain: now.addingTimeInterval(-range.duration)...now)
        .chartYScale(domain: 0...yDomainTop)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(format(v)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .overlay {
            if points.isEmpty {
                Text("Collecting data…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch range {
        case .hour, .day: .dateTime.hour().minute()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.month(.abbreviated).day()
        }
    }

    private var bands: [Band] {
        let order = series.map(\.name)
        let byDate = Dictionary(grouping: points, by: \.date)
        var result: [Band] = []
        for date in byDate.keys.sorted() {
            var cumulative = 0.0
            let group = byDate[date] ?? []
            for name in order {
                guard let point = group.first(where: { $0.series == name }) else { continue }
                result.append(Band(date: date, start: cumulative, end: cumulative + point.value,
                                   series: name, segmentKey: "\(name)#\(point.segment)"))
                cumulative += point.value
            }
        }
        return result
    }

    private var yDomainTop: Double {
        if let yMax { return yMax }
        let top: Double
        if stacked {
            top = Dictionary(grouping: points, by: \.date).values.map { $0.reduce(0) { $0 + $1.value } }.max() ?? 0
        } else {
            top = points.map(\.value).max() ?? 0
        }
        return max(top, reference?.value ?? 0, 1) * 1.15
    }
}

/// Circular score gauge.
struct HealthRing: View {
    let score: Int
    var lineWidth: CGFloat = 12
    var showsLabel = true

    var body: some View {
        let color = Theme.health(score)
        ZStack {
            GaugeRing(fraction: Double(score) / 100, color: color, lineWidth: lineWidth)
            if showsLabel {
                VStack(spacing: 0) {
                    RollingText("\(score)", size: 40)
                    Text("Health")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Horizontal bar split into labeled segments (memory breakdown, disk usage).
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var id: String { label }
    }

    let segments: [Segment]
    var height: CGFloat = 14

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.value }, 1)
        var cumulative = 0.0
        let ranges: [(Segment, Double, Double)] = segments.map { segment in
            let start = cumulative / total
            cumulative += segment.value
            return (segment, start, cumulative / total)
        }
        // Core Animation segments: they glide without per-frame work in our process.
        LayerSegments(segments: ranges.map { .init(id: $0.0.id, start: $0.1, end: $0.2, color: $0.0.color) })
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Thin horizontal fill bar, 0...1.
struct MeterBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        // Track in SwiftUI (static), fill in Core Animation (glides without per-frame work in-app).
        ZStack {
            Capsule().fill(.quaternary)
            LayerBar(fraction: fraction, color: tint)
        }
        .frame(height: height)
    }
}
