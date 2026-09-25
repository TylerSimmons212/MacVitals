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
    /// Roll digits on change. Off by default: values that change every refresh should update
    /// crisply (rolling them kept SwiftUI animating nearly nonstop).
    var rolls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let term {
                    Text(term.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .modifier(RollingIf(enabled: rolls, value: value))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

private struct RollingIf: ViewModifier {
    let enabled: Bool
    let value: String
    func body(content: Content) -> some View {
        if enabled { content.rollingNumber(value) } else { content }
    }
}
