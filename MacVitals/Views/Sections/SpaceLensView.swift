import SwiftUI

/// Space Lens: a ring chart of what's taking up space. The folder you're in sits in the middle,
/// its contents ring around it, and their contents around those. Click a slice to go in,
/// the middle to go back out. The list beside it says the same thing in words, with
/// Reveal and Move to Trash.
struct SpaceLensView: View {
    @Environment(SpaceLensModel.self) private var model
    @Environment(CleanupEngine.self) private var engine
    @Environment(Permissions.self) private var permissions
    @State private var hovered: SpaceNode?
    @State private var pendingTrash: SpaceNode?

    var body: some View {
        SectionScroll {
            if let record = engine.lastRecord {
                CleanupResultBanner(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            switch model.phase {
            case .idle: start.entrance()
            case .scanning: scanning.transition(.opacity)
            case .ready:
                if let current = model.current {
                    header(current).entrance()
                    explorer(current).entrance(delay: 0.04)
                    footnote.entrance(delay: 0.08)
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.phase)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: engine.lastRecord?.id)
        .confirmationDialog(pendingTrash.map { "Move \($0.name) to the Trash?" } ?? "",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            presenting: pendingTrash) { node in
            Button("Move to Trash", role: .destructive) {
                Task { await model.trash(node, engine: engine) }
            }
        } message: { node in
            Text([SpaceLensModel.caution(for: node.path), "\(Fmt.bytes(node.size)) goes to the Trash. You can put it back until you empty the Trash."]
                .compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    // MARK: Start

    private var start: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 22) {
                ZStack {
                    Circle().fill(Theme.cleanup.opacity(0.12))
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.cleanup.gradient)
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 8) {
                    Text("See what's taking up space").font(.title2.weight(.semibold))
                    Text("Space Lens measures every folder and draws it as rings: the bigger the slice, the more space it takes. Click into any slice to see what's inside. Nothing is removed unless you choose to.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                TargetButton(title: "Home folder", subtitle: "Your files, apps' data and caches",
                             icon: "house.fill", lastSize: SpaceLensModel.lastSize(of: SpaceLensModel.Target.home.path)) {
                    Task { await model.scan(.home) }
                }
                TargetButton(title: "Whole Mac", subtitle: "Everything on Macintosh HD",
                             icon: "internaldrive.fill", lastSize: SpaceLensModel.usedSpace()) {
                    Task { await model.scan(.wholeMac) }
                }
                TargetButton(title: "Choose a folder…", subtitle: "Any folder or external disk",
                             icon: "folder.fill.badge.plus", lastSize: nil) {
                    Task { await model.chooseFolder() }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !permissions.hasFullDiskAccess {
                PermissionCallout(kind: .fullDiskAccess,
                                  message: "Without Full Disk Access, macOS hides Mail, Messages and some app data from the scan. They'll show as \"couldn't be read\".")
            }
        }
        .cardStyle(padding: 20, tint: Theme.cleanup)
    }

    // MARK: Scanning

    private var scanning: some View {
        HStack(spacing: 24) {
            ScanOrb(scanning: true, progress: model.progress ?? 0, animated: true)
                .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 8) {
                Text("Measuring \(model.target.title)…").font(.title2.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RollingText(model.filesScanned.formatted(), size: 22, weight: .semibold, alignment: .leading)
                    Text("files").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    RollingText(Fmt.bytes(model.bytesScanned), size: 22, weight: .semibold, alignment: .leading)
                }
                Text(model.progress == nil
                     ? "The first scan of a folder takes a minute or two on a full disk. iCloud Drive folders are the slowest."
                     : "About \(Int((model.progress ?? 0) * 100))% done.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.glass).pointerStyle(.link).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: Theme.cleanup)
    }

    // MARK: Ready

    private func header(_ current: SpaceNode) -> some View {
        HStack(spacing: 10) {
            Menu {
                Button("Home folder") { Task { await model.scan(.home) } }
                Button("Whole Mac") { Task { await model.scan(.wholeMac) } }
                Divider()
                Button("Choose a Folder…") { Task { await model.chooseFolder() } }
            } label: {
                Label(model.target.title, systemImage: model.target == .wholeMac ? "internaldrive" : "folder")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .pointerStyle(.link)
            .help("Scan something else")

            Breadcrumbs(lineage: current.lineage) { model.open($0) }

            Spacer(minLength: 8)
            Button {
                Task { await model.scan(model.target) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .pointerStyle(.link)
            .help("Scan again")
        }
    }

    private func explorer(_ current: SpaceNode) -> some View {
        HStack(alignment: .top, spacing: 16) {
            SunburstChart(current: current, revision: model.revision, hovered: $hovered,
                          open: { node in withAnimation(.smooth) { model.open(node) } },
                          up: { withAnimation(.smooth) { model.goUp() } },
                          canGoUp: model.canGoUp)
                .frame(minWidth: 380, idealWidth: 460, maxWidth: 520, minHeight: 380, idealHeight: 460, maxHeight: 520)
                .aspectRatio(1, contentMode: .fit)
                .cardStyle(padding: 14)

            SpaceItemList(current: current, revision: model.revision, hovered: $hovered,
                          open: { node in withAnimation(.smooth) { model.open(node) } },
                          trash: { pendingTrash = $0 })
                .frame(maxWidth: .infinity)
                .cardStyle(padding: 14, fillHeight: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("Measured \(model.filesScanned.formatted()) files in \(Int(model.scanDuration.rounded())) s\(model.scanDate.map { ", \($0.formatted(.relative(presentation: .named)))" } ?? ""). Sizes are space actually used on disk; files not downloaded from iCloud count as zero.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.unreadableFolders > 0 {
                if permissions.hasFullDiskAccess {
                    Text("\(model.unreadableFolders.formatted()) folders couldn't be read. They belong to macOS or other users, so their size is part of \"macOS and hidden space\".")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    PermissionCallout(kind: .fullDiskAccess,
                                      message: "\(model.unreadableFolders.formatted()) folders couldn't be read because macOS protects them. Allow Full Disk Access to include them.") {
                        Task { await model.scan(model.target) }
                    }
                }
            }
        }
    }
}

// MARK: - Start buttons

private struct TargetButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let lastSize: Int64?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.cleanup)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let lastSize {
                    Text(Fmt.bytes(lastSize)).font(.caption.weight(.semibold)).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .cardStyle(padding: 14, interactive: true, fillHeight: true)
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hovering)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}

// MARK: - Breadcrumbs

private struct Breadcrumbs: View {
    let lineage: [SpaceNode]
    let open: (SpaceNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(lineage.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    let isLast = index == lineage.count - 1
                    Button {
                        open(node)
                    } label: {
                        Text(verbatim: index == 0 ? rootName(node) : node.name)
                            .font(.callout.weight(isLast ? .semibold : .regular))
                            .foregroundStyle(isLast ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(isLast ? nil : .link)
                    .disabled(isLast)
                }
            }
        }
        .defaultScrollAnchor(.trailing)
    }

    private func rootName(_ node: SpaceNode) -> String {
        node.path == "/System/Volumes/Data" ? "Macintosh HD" : FileManager.default.displayName(atPath: node.path)
    }
}

// MARK: - Palette

enum SpacePalette {
    static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .yellow, .cyan, .red, .mint, .brown]

    static func color(for node: SpaceNode, branch: Int) -> Color {
        switch node.kind {
        case .smallFiles: .gray
        case .hidden: Color(white: 0.55)
        default: colors[branch % colors.count]
        }
    }
}

// MARK: - Chart

private struct SunburstChart: View {
    let current: SpaceNode
    let revision: Int
    @Binding var hovered: SpaceNode?
    let open: (SpaceNode) -> Void
    let up: () -> Void
    let canGoUp: Bool

    @State private var segments: [Sunburst.Segment] = []
    @State private var reveal: Double = 1
    @Environment(\.motionEnabled) private var motionEnabled

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let geometry = Sunburst.Geometry(radius: side / 2 - 2, rings: 3)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                SunburstCanvas(segments: segments, geometry: geometry, hovered: hovered, reveal: reveal)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let point = CGPoint(x: location.x - center.x, y: location.y - center.y)
                            let hit = Sunburst.hit(point, in: segments, geometry: geometry)?.node
                            if hit !== hovered { hovered = hit }
                        case .ended:
                            hovered = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        let point = CGPoint(x: value.location.x - center.x, y: value.location.y - center.y)
                        if let node = Sunburst.hit(point, in: segments, geometry: geometry)?.node {
                            if node.isFolder { hovered = nil; open(node) }
                        }
                    })
                    .pointerStyle(hovered?.isFolder == true ? .link : nil)

                CenterDisc(current: current, hovered: hovered, canGoUp: canGoUp, up: up)
                    .frame(width: geometry.hole * 2 - 8, height: geometry.hole * 2 - 8)
            }
        }
        .task(id: "\(current.id.hashValue)|\(revision)") {
            segments = Sunburst.layout(current, rings: 3)
            guard motionEnabled else { reveal = 1; return }
            reveal = 0
            withAnimation(.easeOut(duration: 0.7)) { reveal = 1 }
        }
    }
}

/// Draws the rings. Animatable so a new folder sweeps in clockwise (drawn only while it
/// animates; otherwise it redraws just when the hover changes).
struct SunburstCanvas: View, Animatable {
    let segments: [Sunburst.Segment]
    let geometry: Sunburst.Geometry
    let hovered: SpaceNode?
    var reveal: Double

    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for segment in segments {
                // Radar sweep: a line turns clockwise from 12 o'clock uncovering the rings as
                // `reveal` goes 0 → 1; outer rings trail slightly behind.
                let lag = Double(segment.depth - 1) * 0.12
                let cutoff = max(0, min(1, (reveal - lag) / (1 - lag)))
                guard segment.start < cutoff else { continue }
                let start = segment.start
                let end = min(segment.end, cutoff)
                guard end - start > 0.0005 else { continue }

                let path = Self.sector(center: center, inner: geometry.inner(segment.depth) + 1.5,
                                       outer: geometry.outer(segment.depth) - 1.5, start: start, end: end)
                let isHovered = hovered === segment.node
                let related = hovered.map { $0 === segment.node || $0.isAncestor(of: segment.node) } ?? true
                let base = SpacePalette.color(for: segment.node, branch: segment.branch)
                let depthOpacity = [1.0, 0.72, 0.5][min(segment.depth - 1, 2)] * (segment.node.kind == .file ? 0.85 : 1)
                let opacity = isHovered ? 1 : related ? depthOpacity : depthOpacity * 0.35
                context.fill(path, with: .color(base.opacity(opacity)))
                if isHovered {
                    context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 2)
                }
            }
        }
    }

    /// An annular slice between two radii, from `start` to `end` (fractions of a turn from 12 o'clock).
    static func sector(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        // A small fixed gap between slices, in points, regardless of radius.
        let gapOuter = min(0.9 / Double(outer), (end - start) * .pi * 0.45)
        let gapInner = min(0.9 / Double(max(inner, 1)), (end - start) * .pi * 0.45)
        let a0 = start * 2 * .pi - .pi / 2, a1 = end * 2 * .pi - .pi / 2
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(a0 + gapOuter), endAngle: .radians(a1 - gapOuter), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(a1 - gapInner), endAngle: .radians(a0 + gapInner), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The middle of the chart: the folder you're in, or whatever you're hovering.
private struct CenterDisc: View {
    let current: SpaceNode
    let hovered: SpaceNode?
    let canGoUp: Bool
    let up: () -> Void
    @State private var hovering = false

    var body: some View {
        let shown = hovered ?? current
        Button(action: up) {
            VStack(spacing: 3) {
                if hovered == nil && canGoUp {
                    Image(systemName: "arrow.up.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0.6)
                }
                Text(verbatim: displayName(shown))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                Text(Fmt.bytes(shown.size))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let hovered, hovered !== current, current.size > 0 {
                    Text("\(Int((Double(hovered.size) / Double(current.size) * 100).rounded()))% of \(displayName(current))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else if shown.isFolder {
                    Text("\(shown.fileCount.formatted()) files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(canGoUp && hovered == nil), in: .circle)
        .pointerStyle(canGoUp && hovered == nil ? .link : nil)
        .onHover { hovering = $0 }
        .help(canGoUp ? "Back to the enclosing folder" : "")
        .disabled(!canGoUp)
    }

    private func displayName(_ node: SpaceNode) -> String {
        node.path == "/System/Volumes/Data" ? "Macintosh HD" : node.parent == nil ? FileManager.default.displayName(atPath: node.path) : node.name
    }
}

// MARK: - List

private struct SpaceItemList: View {
    let current: SpaceNode
    let revision: Int
    @Binding var hovered: SpaceNode?
    let open: (SpaceNode) -> Void
    let trash: (SpaceNode) -> Void

    static let limit = 60

    var body: some View {
        let children = current.children.filter { $0.size > 0 || $0.isUnreadable }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(children.count) item\(children.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Text(Fmt.bytes(current.size)).font(.headline).monospacedDigit().foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(children.prefix(Self.limit).enumerated()), id: \.element.id) { index, child in
                        SpaceRow(node: child, parentSize: current.size,
                                 color: SpacePalette.color(for: child, branch: current.children.firstIndex { $0 === child } ?? index),
                                 highlighted: hovered === child || (hovered.map { child.isAncestor(of: $0) } ?? false),
                                 open: { open(child) }, trash: { trash(child) })
                            .onHover { inside in
                                if inside { hovered = child } else if hovered === child { hovered = nil }
                            }
                    }
                    if children.count > Self.limit {
                        Text("\(children.count - Self.limit) smaller items not shown")
                            .font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
                    }
                }
            }
            .frame(maxHeight: 480)
        }
        .id(revision)
    }
}

private struct SpaceRow: View {
    let node: SpaceNode
    let parentSize: Int64
    let color: Color
    let highlighted: Bool
    let open: () -> Void
    let trash: () -> Void
    @State private var hovering = false

    private var share: Double { parentSize > 0 ? Double(node.size) / Double(parentSize) : 0 }

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: node.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if node.isUnreadable {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                            .help("macOS didn't let Mac Vitals read this folder")
                    }
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    LayerBar(fraction: share, color: color, duration: 0)
                }
                .frame(height: 4)
            }
            Spacer(minLength: 6)
            if hovering && node.isReal {
                Button { ProcessController.revealInFinder(node.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                    .help("Show in Finder")
                if !CleanupRemover.isProtected(node.path) {
                    Button(action: trash) { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                        .help("Move to Trash…")
                }
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.bytes(node.size)).font(.callout.weight(.semibold)).monospacedDigit()
                Text(share >= 0.001 ? "\(String(format: share >= 0.1 ? "%.0f" : "%.1f", share * 100))%" : "<0.1%")
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            .frame(minWidth: 64, alignment: .trailing)
            if node.isFolder && !node.children.isEmpty {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            } else {
                Color.clear.frame(width: 7)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(highlighted ? 0.14 : hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if node.isFolder { open() } }
        .pointerStyle(node.isFolder && !node.children.isEmpty ? .link : nil)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        switch node.kind {
        case .folder, .file:
            Image(nsImage: IconCache.shared.icon(forPath: node.path)).resizable().interpolation(.high)
        case .smallFiles:
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
        case .hidden:
            Image(systemName: "eye.slash").foregroundStyle(.secondary)
        }
    }
}
