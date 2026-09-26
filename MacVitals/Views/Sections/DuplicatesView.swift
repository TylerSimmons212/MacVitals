import SwiftUI
import QuickLookThumbnailing

/// Duplicates: files with byte-for-byte identical contents, with the space you'd *really* get
/// back (copies that already share their data on APFS free nothing, so they're set aside).
/// One copy of everything always stays, and removals go to the Trash.
struct DuplicatesView: View {
    @Environment(DuplicatesModel.self) private var model
    @Environment(CleanupEngine.self) private var engine
    @Environment(Permissions.self) private var permissions
    @State private var confirming = false
    @State private var shown = 60
    @AppStorage("duplicates.mode") private var similarMode = false

    var body: some View {
        SectionScroll {
            if let record = engine.lastRecord {
                CleanupResultBanner(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Picker("Find", selection: $similarMode) {
                Text("Identical Files").tag(false)
                Text("Similar Photos").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .pointerStyle(.link)
            .frame(maxWidth: .infinity)
            if similarMode {
                SimilarPhotosSection()
            } else {
                identical
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: similarMode)
        .modifier(IdenticalDialogs(model: model, engine: engine, confirming: $confirming))
    }

    @ViewBuilder
    private var identical: some View {
            switch model.phase {
            case .idle: setup.entrance()
            case .scanning: scanning.transition(.opacity)
            case .ready:
                summary.entrance()
                if !model.groups.isEmpty {
                    filters.entrance(delay: 0.04)
                    groupList.entrance(delay: 0.08)
                }
                setup.entrance(delay: 0.1)
            }
    }
}

private struct IdenticalDialogs: ViewModifier {
    let model: DuplicatesModel
    let engine: CleanupEngine
    @Binding var confirming: Bool

    func body(content: Content) -> some View {
        content
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.phase)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: engine.lastRecord?.id)
        .confirmationDialog("Move \(model.selectedFiles.count) duplicate\(model.selectedFiles.count == 1 ? "" : "s") to the Trash?",
                            isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await model.removeSelected(engine: engine) } }
        } message: {
            let iCloud = model.selectedFiles.filter(\.isInICloudDrive).count
            Text("Frees \(Fmt.bytes(model.selectedSize)) once the Trash is emptied. One copy of each file stays where it is. You can put them back until then."
                 + (iCloud > 0 ? "\n\n\(iCloud) of them \(iCloud == 1 ? "is" : "are") in iCloud Drive, so \(iCloud == 1 ? "it's" : "they're") removed from your other devices too." : ""))
        }
    }
}

extension DuplicatesView {

    // MARK: Summary

    private var summary: some View {
        let potential = model.totalPotential
        let tint: Color = potential > 0 ? Theme.cleanup : .green
        return HStack(spacing: 22) {
            ZStack {
                GaugeRing(fraction: potential > 0 ? Double(model.selectedSize) / Double(potential) : 1, color: tint, lineWidth: 12)
                VStack(spacing: 0) {
                    RollingText(Fmt.bytes(model.selectedSize), size: 22)
                    Text("selected").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
            }
            .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                if model.groups.filter({ !$0.sharesSpace }).isEmpty {
                    Text("No duplicates taking up space").font(.title2.weight(.semibold))
                    Text(model.sharedSpaceGroups > 0
                         ? "\(model.sharedSpaceGroups) set\(model.sharedSpaceGroups == 1 ? " of copies shares" : "s of copies share") the same data on disk (like Finder duplicates), so removing them wouldn't free anything."
                         : "Checked \(model.filesListed.formatted()) files of \(DuplicatesModel.sizeLabel(model.minimumSize)) or more. Every one is unique.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(Fmt.bytes(potential)) in duplicate copies").font(.title2.weight(.semibold))
                    Text("\(model.extraCopies) extra cop\(model.extraCopies == 1 ? "y" : "ies") of \(model.groups.filter { !$0.sharesSpace }.count) file\(model.groups.filter { !$0.sharesSpace }.count == 1 ? "" : "s"), matched byte for byte. Mac Vitals picked the copy to keep in each (the one in a proper folder, with the original name); change any you like.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            confirming = true
                        } label: {
                            Label("Move \(model.selectedFiles.count) to Trash", systemImage: "trash")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.cleanup)
                        .pointerStyle(.link)
                        .disabled(model.selectedFiles.isEmpty)
                        Button("Select Automatically") { withAnimation(.smooth) { model.autoSelect() } }
                            .buttonStyle(.glass).pointerStyle(.link)
                        Button("Deselect All") { withAnimation(.smooth) { model.deselectAll() } }
                            .buttonStyle(.glass).pointerStyle(.link)
                            .disabled(model.selectedFiles.isEmpty)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: tint)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            FilterChip(title: "All", count: model.count(of: nil), selected: model.kindFilter == nil) { model.kindFilter = nil }
            ForEach(DuplicateGroup.Kind.allCases, id: \.self) { kind in
                let count = model.count(of: kind)
                if count > 0 {
                    FilterChip(title: kind.title, icon: kind.icon, count: count, selected: model.kindFilter == kind) {
                        model.kindFilter = model.kindFilter == kind ? nil : kind
                    }
                }
            }
            Spacer(minLength: 8)
            if model.sharedSpaceGroups > 0 {
                @Bindable var model = model
                Toggle("Show copies that share space (\(model.sharedSpaceGroups))", isOn: $model.showSharedSpace)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .pointerStyle(.link)
                    .help("Copies made with Finder's Duplicate share their data on disk, so removing them frees nothing.")
            }
        }
    }

    private var groupList: some View {
        let groups = model.visibleGroups
        return LazyVStack(spacing: 12) {
            ForEach(groups.prefix(shown)) { group in
                DuplicateGroupCard(group: group)
            }
            if groups.count > shown {
                Button("Show \(min(60, groups.count - shown)) More") { shown += 60 }
                    .buttonStyle(.glass).pointerStyle(.link)
            }
        }
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.phase == .idle {
                HStack(spacing: 22) {
                    ZStack {
                        Circle().fill(Theme.cleanup.opacity(0.12))
                        Image(systemName: "doc.on.doc.fill").font(.system(size: 42)).foregroundStyle(Theme.cleanup.gradient)
                    }
                    .frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Find duplicate files").font(.title2.weight(.semibold))
                        Text("Finds files that are exactly the same, byte for byte, and shows how much space you'd really get back. You choose what goes; one copy of everything always stays, and everything goes to the Trash first.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Search settings").font(.headline)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Look in").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                FolderChips(folders: model.folders, remove: { model.removeFolder($0) })
                HStack(spacing: 10) {
                    Button { model.addFolder() } label: { Label("Add Folder…", systemImage: "plus") }
                        .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                    Button("Reset") { model.resetFolders() }
                        .buttonStyle(.link).font(.callout).pointerStyle(.link)
                    Spacer()
                    Text("Ignore files smaller than").font(.callout).foregroundStyle(.secondary)
                    Menu(DuplicatesModel.sizeLabel(model.minimumSize)) {
                        ForEach(DuplicatesModel.sizeOptions, id: \.0) { option in
                            Button(option.1) { model.minimumSize = option.0 }
                        }
                    }
                    .fixedSize()
                    .pointerStyle(.link)
                }
                Text("App bundles, code repositories, node_modules and hidden folders are skipped: copies there are deliberate. Files not downloaded from iCloud are skipped too.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if !permissions.hasFullDiskAccess {
                PermissionCallout(kind: .fullDiskAccess, message: "Without Full Disk Access, macOS asks separately for Documents, Desktop and Downloads, and some folders may be skipped.")
            }
            HStack {
                Spacer()
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(model.phase == .ready ? "Search Again" : "Find Duplicates", systemImage: "magnifyingglass")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.cleanup)
                .controlSize(.large)
                .pointerStyle(.link)
                .disabled(model.folders.isEmpty)
            }
        }
        .cardStyle(padding: 20, tint: model.phase == .idle ? Theme.cleanup : nil)
    }

    private var scanning: some View {
        HStack(spacing: 24) {
            ScanOrb(scanning: true, progress: model.comparing ? model.compareFraction : 0, animated: true)
                .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.comparing ? "Comparing possible duplicates…" : "Looking through your files…").font(.title2.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RollingText(model.filesListed.formatted(), size: 22, weight: .semibold, alignment: .leading)
                    Text("files checked").foregroundStyle(.secondary)
                }
                Text(model.comparing
                     ? "Only files with exactly the same size are compared, first by their beginning and end, then in full. \(Int(model.compareFraction * 100))% done."
                     : "Grouping files by size. Files that differ in size can't be duplicates, so most are ruled out right away.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Cancel") { model.cancel() }.buttonStyle(.glass).pointerStyle(.link).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: Theme.cleanup)
    }
}

extension DuplicatesModel {
    static func sizeLabel(_ size: Int64) -> String {
        sizeOptions.first { $0.0 == size }?.1 ?? Fmt.bytes(size)
    }
}

// MARK: - Pieces

private struct FilterChip: View {
    let title: String
    var icon: String? = nil
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout.weight(selected ? .semibold : .regular))
        }
        .buttonStyle(.glass)
        .tint(selected ? Theme.cleanup : nil)
        .controlSize(.small)
        .pointerStyle(.link)
    }
}

private struct FolderChips: View {
    let folders: [String]
    let remove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(folders, id: \.self) { folder in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.shared.icon(forPath: folder)).resizable().frame(width: 16, height: 16)
                    Text(verbatim: displayName(folder)).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Button { remove(folder) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).pointerStyle(.link)
                        .help("Don't look here")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .help(folder)
            }
        }
    }

    private func displayName(_ path: String) -> String {
        path.hasSuffix("com~apple~CloudDocs") ? "iCloud Drive" : FileManager.default.displayName(atPath: path)
    }
}

struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @Environment(DuplicatesModel.self) private var model

    var body: some View {
        let keeperPath = KeepChooser.keeper(of: group.files)?.path
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Thumbnail(path: group.files[0].path).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: group.files.first { $0.path == keeperPath }?.name ?? group.files[0].name)
                        .font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text("\(group.files.count) identical copies · \(Fmt.bytes(group.size)) each")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if group.sharesSpace {
                    Label("Shares space", systemImage: "link")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .help("These copies share the same data on disk, so removing one frees nothing.")
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.bytes(model.potential(group))).font(.callout.weight(.semibold)).monospacedDigit()
                        Text("to free").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            VStack(spacing: 2) {
                ForEach(group.files) { file in
                    CopyRow(file: file, group: group, suggestedKeep: file.path == keeperPath)
                }
            }
        }
        .cardStyle(padding: 14)
    }
}

private struct CopyRow: View {
    let file: DuplicateFile
    let group: DuplicateGroup
    let suggestedKeep: Bool
    @Environment(DuplicatesModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let selected = model.isSelected(file)
        let canToggle = model.canSelect(file, in: group)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in withAnimation(.smooth(duration: 0.2)) { model.toggle(file, in: group) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canToggle)
                .pointerStyle(canToggle ? .link : nil)
                .help(canToggle ? (selected ? "Keep this copy" : "Move this copy to the Trash") : "One copy always stays")
            Image(nsImage: IconCache.shared.icon(forPath: file.folder)).resizable().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: abbreviated(file.folder))
                    .font(.callout).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(selected ? .secondary : .primary)
                    .strikethrough(selected, color: .secondary)
                HStack(spacing: 6) {
                    Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                    Text("·")
                    Text("Modified \(file.modified.formatted(date: .abbreviated, time: .omitted))")
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if file.isInICloudDrive {
                Image(systemName: "icloud").foregroundStyle(.blue)
                    .help("In iCloud Drive: removing it also removes it from your other devices")
            }
            if !selected {
                Text(suggestedKeep ? "Keep" : "Keeping")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
            }
            Button { ProcessController.revealInFinder(file.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                .opacity(hovering ? 1 : 0.4)
                .help("Show in Finder")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/Library/Mobile Documents/com~apple~CloudDocs") {
            return "iCloud Drive" + path.dropFirst((home + "/Library/Mobile Documents/com~apple~CloudDocs").count)
        }
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Quick Look thumbnail (photos, videos, PDFs…), falling back to the file's icon.
private struct Thumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: IconCache.shared.icon(forPath: path)).resizable().padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: path) {
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 88, height: 88),
                                                       scale: 2, representationTypes: .thumbnail)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = thumbnail.nsImage
            }
        }
    }
}
