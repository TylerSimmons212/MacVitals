import SwiftUI

/// The "Similar Photos" half of Duplicates: sets of near-identical shots, best one suggested.
struct SimilarPhotosSection: View {
    @Environment(SimilarPhotosModel.self) private var model
    @Environment(DuplicatesModel.self) private var duplicates
    @Environment(CleanupEngine.self) private var engine
    @Environment(Permissions.self) private var permissions
    @State private var confirming = false
    @State private var shown = 40

    var body: some View {
        Group {
            hero.entrance()
            if model.source == .library && !permissions.isGranted(.photos) {
                PermissionCallout(kind: .photos, message: "Allow Photos so Mac Vitals can look for near-identical shots in your library. Photos are analyzed on this Mac and never leave it.")
            }
            if model.phase == .ready && !model.groups.isEmpty {
                LazyVStack(spacing: 12) {
                    ForEach(model.groups.prefix(shown)) { group in
                        SimilarGroupCard(group: group)
                    }
                    if model.groups.count > shown {
                        Button("Show More (\(model.groups.count - shown))") { shown += 40 }
                            .buttonStyle(.glass).pointerStyle(.link)
                    }
                }
                .entrance(delay: 0.06)
            }
        }
        .confirmationDialog("Delete \(model.selected.count) photo\(model.selected.count == 1 ? "" : "s")?", isPresented: $confirming) {
            Button(model.source == .library ? "Delete from Photos" : "Move to Trash", role: .destructive) {
                Task { await model.deleteSelected(engine: engine) }
            }
        } message: {
            Text(model.source == .library
                 ? "Photos will ask you to confirm. They stay in Recently Deleted for 30 days. With iCloud Photos, they're removed from your other devices too."
                 : "They go to the Trash, so you can put them back until it's emptied.")
        }
    }

    private var hero: some View {
        HStack(spacing: 22) {
            ZStack {
                if model.phase == .analyzing {
                    ScanOrb(scanning: true, progress: model.total > 0 ? Double(model.analyzed) / Double(model.total) : 0, animated: true)
                } else {
                    Circle().fill(Theme.cleanup.opacity(0.12))
                    Image(systemName: "square.stack.3d.down.right.fill").font(.system(size: 40)).foregroundStyle(Theme.cleanup.gradient)
                }
            }
            .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    switch model.phase {
                    case .idle: Text("Find near-identical photos")
                    case .analyzing: Text("Looking at \(model.analyzed.formatted()) of \(model.total.formatted()) photos…")
                    case .ready: Text(model.groups.isEmpty ? "No similar photos found" : "\(model.groups.count) sets of similar photos")
                    }
                }
                .font(.title2.weight(.semibold))
                Text(model.phase == .ready && !model.groups.isEmpty
                     ? "\(model.extraPhotos) extra shot\(model.extraPhotos == 1 ? "" : "s"). In each set, Mac Vitals suggests the best one (sharpest, best composed, by Apple's photo scoring) and selects the rest. Favorites are never selected for you."
                     : "Bursts, retakes and slightly different versions of the same moment. Photos are compared on this Mac with Apple's image analysis, only with others taken within a few minutes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    @Bindable var model = model
                    Picker("Source", selection: $model.source) {
                        Text("Photos Library").tag(SimilarPhotosModel.Source.library)
                        Text("Folders").tag(SimilarPhotosModel.Source.folders)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().pointerStyle(.link)
                    .disabled(model.phase == .analyzing)
                    if model.source == .library {
                        Picker("Range", selection: $model.wholeLibrary) {
                            Text("Last 12 months").tag(false)
                            Text("Whole library").tag(true)
                        }
                        .labelsHidden().fixedSize().pointerStyle(.link)
                        .disabled(model.phase == .analyzing)
                    }
                    Spacer(minLength: 0)
                    if model.phase == .analyzing {
                        Button("Cancel") { model.cancel() }.buttonStyle(.glass).pointerStyle(.link)
                    } else {
                        if model.phase == .ready && !model.groups.isEmpty {
                            Button("Select Automatically") { model.autoSelect() }.buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                            Button {
                                confirming = true
                            } label: {
                                Label("Delete \(model.selected.count)\(model.selectedSize > 0 ? " (\(Fmt.bytes(model.selectedSize)))" : "")", systemImage: "trash")
                            }
                            .buttonStyle(.glassProminent).tint(Theme.cleanup).controlSize(.small).pointerStyle(.link)
                            .disabled(model.selected.isEmpty)
                        }
                        if model.phase == .ready {
                            Button("Look Again") { Task { await model.scan(folders: duplicates.folders) } }
                                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                        } else {
                            Button("Find Similar Photos") { Task { await model.scan(folders: duplicates.folders) } }
                                .buttonStyle(.glassProminent).tint(Theme.cleanup).pointerStyle(.link)
                                .disabled(model.source == .library && !permissions.isGranted(.photos))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: Theme.cleanup)
    }
}

private struct SimilarGroupCard: View {
    let group: SimilarPhotosModel.Group
    @Environment(SimilarPhotosModel.self) private var model

    var body: some View {
        let best = group.best
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(group.photos.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "").font(.headline)
                Text("· \(group.photos.count) photos\(group.span > 1 ? " within \(Self.describe(group.span))" : "")")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.photos) { photo in
                        PhotoChoice(photo: photo, isBest: photo.id == best?.id, selected: model.isSelected(photo),
                                    canToggle: model.canSelect(photo, in: group)) {
                            withAnimation(.smooth(duration: 0.15)) { model.toggle(photo, in: group) }
                        }
                    }
                }
            }
        }
        .cardStyle(padding: 14)
    }

    static func describe(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }
}

private struct PhotoChoice: View {
    let photo: SimilarPhotosModel.Photo
    let isBest: Bool
    let selected: Bool
    let canToggle: Bool
    let toggle: () -> Void
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Image(systemName: selected ? "trash.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, selected ? Color.red : Color.green)
                    .padding(6)
                    .opacity(canToggle || !selected ? 1 : 0.5)
            }
            .frame(width: 150, height: 150)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.red.opacity(0.8) : isBest ? Color.green : .clear, lineWidth: 2.5))
            .opacity(selected ? 0.6 : 1)
            HStack(spacing: 4) {
                if isBest { Text("Best").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                if photo.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink) }
                Text(selected ? "Delete" : "Keep").font(.caption).foregroundStyle(selected ? .red : .secondary)
                if let size = photo.size { Text("· \(Fmt.bytes(size))").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if canToggle { toggle() } }
        .pointerStyle(canToggle ? .link : nil)
        .help(canToggle ? (selected ? "Keep this one" : "Delete this one") : "One photo in each set always stays")
        .task(id: photo.id) { image = await ThumbnailCache.shared.image(for: photo.origin, maxPixel: 320) }
    }
}
