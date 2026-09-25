import SwiftUI

struct DashboardView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Router.self) private var router
    @Environment(CleanupEngine.self) private var cleanup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @AppStorage(SettingsKeys.ambientMotion) private var ambientMotion = true

    var body: some View {
        let motion = MotionPolicy.resolve(reduceMotion: reduceMotion, userEnabled: ambientMotion, active: appearsActive)
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            ZStack {
                AmbientBackground(
                    tint: Theme.health(monitor.health.score),
                    arrangement: DashboardSection.allCases.firstIndex(of: router.section) ?? 0,
                    animated: motion.enabled
                )
                    .backgroundExtensionEffect()
                detail
                    .id(router.section)
                    .transition(.blurReplace.combined(with: .scale(0.985)))
            }
            .animation(.smooth(duration: 0.35), value: router.section)
            .navigationTitle(router.section.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    GuideButton(section: router.section)
                        .id(router.section)
                }
            }
        }
        .environment(\.motionEnabled, motion.enabled)
        .tracksVisibility(as: "dashboard", monitor: monitor)
    }


    private var sidebar: some View {
        let selection = Binding<DashboardSection?>(
            get: { router.section },
            set: { if let value = $0 { router.section = value } }
        )
        return List(selection: selection) {
            Section("Vitals") {
                ForEach(DashboardSection.vitals) { section in
                    if section != .battery || monitor.hasBattery {
                        Label(section.title, systemImage: section.icon)
                            .badge(badge(for: section))
                            .tag(section)
                    }
                }
            }
            Section("Tools") {
                ForEach(DashboardSection.tools) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
            Section("Clean Up") {
                ForEach(DashboardSection.cleanUp) { section in
                    Label(section.title, systemImage: section.icon)
                        .badge(cleanupBadge(for: section))
                        .tag(section)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarHealthFooter(score: monitor.health.score, grade: monitor.health.grade) {
                router.section = .overview
            }
            .padding(12)
        }
    }

    private func cleanupBadge(for section: DashboardSection) -> Text? {
        guard section == .cleanup, cleanup.phase == .ready, cleanup.totalFound > 0 else { return nil }
        return Text(Fmt.bytes(cleanup.totalFound))
    }

    private func badge(for section: DashboardSection) -> Text? {
        switch section {
        case .overview: return Text("\(monitor.health.score)")
        case .cpu: return Text(Fmt.percent(monitor.cpu.total))
        case .memory: return Text(Fmt.percent(monitor.memory.usedPercent))
        case .disk: return Text(Fmt.percent(monitor.disk.freePercent) + " free")
        case .battery: return monitor.battery.map { Text(Fmt.percent($0.percent)) }
        default: return nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.section {
        case .overview: OverviewView()
        case .cpu: CPUView()
        case .memory: MemoryView()
        case .disk: DiskView()
        case .network: NetworkView()
        case .battery: BatteryView()
        case .apps: AppsView()
        case .ports: PortsView()
        case .cleanup: SmartCleanView()
        case .junk: JunkView()
        case .uninstaller: UninstallerView()
        case .startup: StartupItemsView()
        }
    }
}

private struct SidebarHealthFooter: View {
    let score: Int
    let grade: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HealthRing(score: score, lineWidth: 4, showsLabel: false)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Health \(score)")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .rollingNumber(score)
                    Text(grade).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
            .glassEffect(.regular.tint(Theme.health(score).opacity(0.15)).interactive(), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}
