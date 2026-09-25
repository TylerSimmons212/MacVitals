import SwiftUI

enum Theme {
    static let cpu = Color.blue
    static let cpuSystem = Color.red
    static let memory = Color.purple
    static let disk = Color.orange
    static let network = Color.teal
    static let upload = Color.pink
    static let battery = Color.green
    static let cleanup = Color.mint

    static func health(_ score: Int) -> Color {
        switch score {
        case 90...: .green
        case 75..<90: .mint
        case 55..<75: .yellow
        case 35..<55: .orange
        default: .red
        }
    }

    static func severity(_ severity: HealthIssue.Severity) -> Color {
        switch severity {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }

    static func severityIcon(_ severity: HealthIssue.Severity) -> String {
        switch severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    static func pressure(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    static func thermal(_ level: ThermalLevel) -> Color {
        switch level {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }

    static func cpuLevel(_ level: CPUInsights.Level) -> Color {
        switch level {
        case .relaxed: .green
        case .busy: cpu
        case .workingHard: .orange
        case .maxedOut: .red
        }
    }

    static func memoryLevel(_ level: MemoryInsights.Level) -> Color {
        switch level {
        case .comfortable: .green
        case .recentlyTight: memory
        case .gettingTight: .orange
        case .underStrain: .red
        }
    }

    static func diskLevel(_ level: DiskInsights.Level) -> Color {
        switch level {
        case .plenty: .green
        case .gettingFull: .yellow
        case .runningLow: .orange
        case .almostFull: .red
        }
    }

    static func storage(_ kind: StorageKind) -> Color {
        switch kind {
        case .apps: .blue
        case .documents: .indigo
        case .downloads: .teal
        case .media: .pink
        case .developer: .orange
        case .backups: .green
        case .mail: .cyan
        case .caches: .brown
        }
    }

    static func networkLevel(_ level: NetworkInsights.Level) -> Color {
        switch level {
        case .checking: .secondary
        case .great: .green
        case .good: network
        case .weakWiFi, .slowInternet: .orange
        case .internetDown, .offline: .red
        }
    }

    static func batteryHealth(_ health: BatteryInsights.Health) -> Color {
        switch health {
        case .healthy: .green
        case .normalWear: battery
        case .serviceSoon: .orange
        case .unknown: .secondary
        }
    }

    static func tier(_ tier: SafetyTier) -> Color {
        switch tier {
        case .safe: .green
        case .review: .yellow
        case .careful: .orange
        }
    }

    /// Green → yellow → red as a percentage climbs.
    static func load(_ percent: Double) -> Color {
        switch percent {
        case ..<60: .green
        case 60..<85: .yellow
        default: .red
        }
    }
}

extension View {
    /// All cards are Liquid Glass floating over the ambient backdrop.
    func cardStyle(padding: CGFloat = 16, tint: Color? = nil, interactive: Bool = false, fillHeight: Bool = false) -> some View {
        glassCard(cornerRadius: 20, tint: tint, interactive: interactive, padding: padding, fillHeight: fillHeight)
    }
}

/// Titled card container used across every section.
struct Card<Content: View, Accessory: View>: View {
    let title: String
    var systemImage: String?
    var tint: Color = .secondary
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    private var fillsHeight = false

    /// Stretch to the height of its row, so side-by-side cards line up.
    /// Pair with `.fixedSize(horizontal: false, vertical: true)` on the row.
    func fillingHeight() -> Card {
        var copy = self
        copy.fillsHeight = true
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                        .labelStyle(TintedIconLabelStyle(tint: tint))
                } else {
                    Text(title)
                }
                Spacer()
                accessory
            }
            .font(.headline)
            content
        }
        .cardStyle(fillHeight: fillsHeight)
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil, tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = EmptyView()
        self.content = content()
    }
}

extension Card {
    init(_ title: String, systemImage: String? = nil, tint: Color = .secondary,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }
}

struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// Small labeled number used in stat rows.
struct StatValue: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Scrollable section body. Glass cards share one container so they render efficiently.
/// The container's `spacing` is the distance at which glass shapes *merge*, not a gap, so it's
/// 0: cards stay separate however tightly they're stacked. (At 16, rows 8pt apart fused together.)
struct SectionScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
            }
            .padding(20)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}
