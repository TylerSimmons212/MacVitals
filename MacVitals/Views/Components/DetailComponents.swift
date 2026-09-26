import SwiftUI

/// Stat card for detail pages: friendly name first, the technical term underneath for
/// people who want it, then the value and a one-line plain-English caption.
struct DetailStat: View {
    let label: String
    var term: String? = nil
    let value: String
    var tint: Color? = nil
    var caption: String? = nil
    var help: String? = nil
    /// Roll digits on change (Core Animation, so it's cheap). Off by default: reserve motion for
    /// the numbers people watch; everything rolling at once is noise.
    var rolls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Label and technical term each get exactly one line, so every card's header is the
            // same height and the numbers line up across a row (no wrapping side by side).
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text((term ?? " ").uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if rolls {
                RollingText(value, size: 24, weight: .semibold, color: tint, alignment: .leading, minimumScale: 0.7)
            } else {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardStyle(padding: 14, fillHeight: true)
        .help(help ?? "")
    }
}

/// Small pill used for inline context ("Mostly Safari", "Throttling").
struct InfoChip: View {
    let text: String
    var icon: String? = nil
    var bundlePath: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            if let bundlePath {
                AppIconView(bundlePath: bundlePath, kind: .application, size: 16)
            } else if let icon {
                Image(systemName: icon).foregroundStyle(tint)
            }
            Text(text).font(.callout.weight(.medium))
        }
        .glassChip(tint: tint == .secondary ? nil : tint)
    }
}
