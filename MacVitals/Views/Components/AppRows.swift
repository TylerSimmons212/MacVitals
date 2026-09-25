import SwiftUI
import AppKit

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    /// Icons are pre-rendered once into a small 64px bitmap. Handing SwiftUI the full
    /// multi-resolution icon made it resample on the CPU every refresh.
    func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let source = NSWorkspace.shared.icon(forFile: path)
        let pixels = 64
        let image = NSImage(size: NSSize(width: 32, height: 32))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        cache[path] = image
        return image
    }
}

struct AppIconView: View {
    let bundlePath: String?
    let kind: AppKind
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let bundlePath {
                Image(nsImage: IconCache.shared.icon(forPath: bundlePath))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: kind == .system ? "apple.logo" : "terminal.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Marks Mac Vitals' own row and explains why it's there.
struct ThisAppBadge: View {
    var body: some View {
        Text("This app")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.cpu.opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.cpu)
            .help("Mac Vitals uses a little CPU while its window is open to keep numbers and charts live. It drops to almost nothing when you close the window.")
    }
}

enum AppMetric {
    case cpu, memory, disk

    func value(_ app: AppUsage) -> Double {
        switch self {
        case .cpu: app.cpu
        case .memory: Double(app.memory)
        case .disk: app.diskTotalRate
        }
    }

    func format(_ app: AppUsage) -> String {
        switch self {
        case .cpu: Fmt.percent(app.cpu, digits: 1)
        case .memory: Fmt.memory(app.memory)
        case .disk: Fmt.rate(app.diskTotalRate)
        }
    }

    var tint: Color {
        switch self {
        case .cpu: Theme.cpu
        case .memory: Theme.memory
        case .disk: Theme.disk
        }
    }
}

/// Ranked list of the heaviest apps for one metric, with inline bars.
struct TopAppsList: View {
    let apps: [AppUsage]
    let metric: AppMetric
    var limit = 8
    var iconSize: CGFloat = 20

    var body: some View {
        let ranked = Array(apps.sorted { metric.value($0) > metric.value($1) }.prefix(limit))
        let top = max(ranked.first.map(metric.value) ?? 0, 0.0001)
        VStack(spacing: 10) {
            if ranked.isEmpty {
                Text("Collecting data…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(ranked) { app in
                HStack(spacing: 10) {
                    AppIconView(bundlePath: app.bundlePath, kind: app.kind, size: iconSize)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(app.name).lineLimit(1)
                            if app.isCurrentApp { ThisAppBadge() }
                            if app.processCount > 1 {
                                Text("\(app.processCount)")
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(metric.format(app))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        MeterBar(fraction: metric.value(app) / top, tint: metric.tint, height: 4)
                    }
                }
            }
        }
    }
}
