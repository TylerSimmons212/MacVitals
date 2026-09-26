import SwiftUI

/// Screenshots: from the Photos library or files. Built for going through lots quickly:
/// filter by age, select old ones in bulk, or review one at a time with the keyboard.
struct ScreenshotsView: View {
    @Environment(ScreenshotsModel.self) private var model
    @Environment(CleanupEngine.self) private var engine
    @Environment(Permissions.self) private var permissions
    @State private var confirming = false
    @State private var shown = 240

    var body: some View {
        SectionScroll {
            if let record = engine.lastRecord {
                CleanupResultBanner(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            hero.entrance()
            if model.source == .library && !permissions.isGranted(.photos) {
                PermissionCallout(kind: .photos, message: "Allow Photos so Mac Vitals can find screenshots in your library. They're only looked at on this Mac.") {
                    Task { await model.load() }
                }
                .entrance(delay: 0.04)
            } else if !model.items.isEmpty {
                toolbar.entrance(delay: 0.04)
                grid.entrance(delay: 0.08)
            }
        }
        .task { if model.phase == .idle { await model.load() } }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.phase)
        .animation(.smooth, value: model.age)
        .sheet(isPresented: Binding(get: { model.reviewIndex != nil }, set: { if !$0 { model.endReview() } })) {
            ScreenshotReview(confirmDelete: { confirming = true })
                .environment(model)
        }
        .confirmationDialog(deleteTitle, isPresented: $confirming) {
            Button(model.source == .library ? "Delete from Photos" : "Move to Trash", role: .destructive) {
                Task { await model.deleteSelected(engine: engine) }
            }
        } message: {
            Text(model.source == .library
                 ? "Photos will ask you to confirm. They stay in Recently Deleted for 30 days, and deleting them there removes them from all your devices using iCloud Photos."
                 : "They go to the Trash, so you can put them back until it's emptied.")
        }
    }

    private var deleteTitle: String {
        let count = model.selected.count
        return "\(model.source == .library ? "Delete" : "Move") \(count) screenshot\(count == 1 ? "" : "s")\(model.source == .files ? " to the Trash" : "")?"
    }

    // MARK: Hero

    private var hero: some View {
        let count = model.items.count
        let old = model.count(.olderThanMonth)
        return HStack(spacing: 22) {
            ZStack {
                GaugeRing(fraction: count == 0 ? 0 : Double(old) / Double(count), color: Theme.cleanup, lineWidth: 12)
                VStack(spacing: 0) {
                    if model.phase == .loading && model.items.isEmpty {
                        ProgressView().controlSize(.small)
                    } else {
                        RollingText("\(count)", size: 28)
                        Text("screenshots").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if count == 0 && model.phase == .ready {
                        Text("No screenshots here")
                    } else if old > 0 {
                        Text("\(old) screenshot\(old == 1 ? " is" : "s are") over a month old")
                    } else {
                        Text("Your recent screenshots")
                    }
                }
                .font(.title2.weight(.semibold))
                Text(model.totalSize > 0
                     ? "\(Fmt.bytes(model.totalSize)) in total. Most screenshots are useful for a moment and then forgotten. Select the old ones in one go, or review them one at a time with the arrow keys."
                     : "Most screenshots are useful for a moment and then forgotten. Select the old ones in one go, or review them one at a time with the arrow keys.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                @Bindable var model = model
                Picker("Source", selection: $model.source) {
                    Text("Photos Library").tag(ScreenshotsModel.Source.library)
                    Text("Files").tag(ScreenshotsModel.Source.files)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .pointerStyle(.link)
                .help(model.source == .files ? "Screenshot files, wherever they are (macOS tags them). New ones are saved to \(FileManager.default.displayName(atPath: ScreenshotsModel.saveFolder))." : "Screenshots in your Photos library, including ones from your iPhone")
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 20, tint: Theme.cleanup)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(ScreenshotsModel.Age.allCases) { age in
                let count = model.count(age)
                if age == .all || count > 0 {
                    Button {
                        model.age = age
                    } label: {
                        HStack(spacing: 5) {
                            Text(age.title)
                            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout.weight(model.age == age ? .semibold : .regular))
                    }
                    .buttonStyle(.glass)
                    .tint(model.age == age ? Theme.cleanup : nil)
                    .controlSize(.small)
                    .pointerStyle(.link)
                }
            }
            Spacer(minLength: 8)
            Button("Select All") { model.selectVisible() }
                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                .help("Select every screenshot shown")
            if !model.selected.isEmpty {
                Button("Deselect") { model.deselectAll() }
                    .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
            }
            Button { model.startReview() } label: { Label("Review", systemImage: "rectangle.stack") }
                .buttonStyle(.glass).controlSize(.small).pointerStyle(.link)
                .help("Go through them one at a time: → keep, ⌫ delete")
            Button {
                confirming = true
            } label: {
                Label(model.selected.isEmpty ? "Delete" : "Delete \(model.selected.count)\(model.selectedSize > 0 ? " (\(Fmt.bytes(model.selectedSize)))" : "")",
                      systemImage: "trash")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.cleanup)
            .controlSize(.small)
            .pointerStyle(.link)
            .disabled(model.selected.isEmpty)
        }
    }

    // MARK: Grid

    private var grid: some View {
        let items = model.visible
        return VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                ForEach(items.prefix(shown)) { item in
                    ScreenshotTile(item: item, selected: model.isSelected(item)) {
                        model.toggle(item)
                    } open: {
                        model.startReview(at: item)
                    }
                }
            }
            if items.count > shown {
                Button("Show More (\(items.count - shown))") { shown += 240 }
                    .buttonStyle(.glass).pointerStyle(.link)
            }
        }
    }
}

private struct ScreenshotTile: View {
    let item: Screenshot
    let selected: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(4)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(hovering ? 0.9 : 0), selected ? Theme.cleanup : .black.opacity(0.35))
                    .padding(8)
            }
            .aspectRatio(1.4, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.cleanup : .clear, lineWidth: 2.5))
            .opacity(selected ? 0.75 : 1)
            HStack {
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let size = item.size { Text(Fmt.bytes(size)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: toggle)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .help("Click to select · double-click to review")
        .task(id: item.id) { image = await ThumbnailCache.shared.image(for: item.origin, maxPixel: 360) }
        .animation(.smooth(duration: 0.15), value: selected)
    }
}

/// One at a time, big: → or K keeps, ⌫ or D marks for deletion, ← goes back.
private struct ScreenshotReview: View {
    let confirmDelete: () -> Void
    @Environment(ScreenshotsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var downloading = false
    @State private var loadFailed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            if model.isReviewFinished {
                finished
            } else if let index = model.reviewIndex, model.reviewList.indices.contains(index) {
                let item = model.reviewList[index]
                HStack {
                    Text("\(index + 1) of \(model.reviewList.count)").font(.headline).monospacedDigit()
                    Spacer()
                    Text(item.date.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                    if let size = item.size { Text("· \(Fmt.bytes(size))").foregroundStyle(.secondary) }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05))
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(6)
                    } else if loadFailed {
                        VStack(spacing: 6) {
                            Image(systemName: "icloud.slash").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Couldn't load this one. It may be in iCloud while you're offline.").foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                    }
                    if downloading && image != nil {
                        Label("Downloading from iCloud…", systemImage: "icloud.and.arrow.down")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.regularMaterial))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(12)
                    }
                    if model.isSelected(item) {
                        Label("Marked for deletion", systemImage: "trash.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(.red.opacity(0.85)))
                            .frame(maxHeight: .infinity, alignment: .top).padding(12)
                    }
                }
                .frame(minHeight: 420)
                .task(id: item.id) {
                    // The grid's small version shows instantly; the full size replaces it.
                    loadFailed = false
                    image = ThumbnailCache.shared.cached(item.origin, maxPixel: 1600)
                        ?? ThumbnailCache.shared.cached(item.origin, maxPixel: 360)
                    downloading = true
                    for await (preview, _) in ThumbnailCache.shared.preview(for: item.origin, maxPixel: 1600) {
                        image = preview
                    }
                    downloading = false
                    if image == nil { loadFailed = true }
                    // Warm the next one so → feels instant.
                    if model.reviewList.indices.contains(index + 1) {
                        ThumbnailCache.shared.prefetch(model.reviewList[index + 1].origin, maxPixel: 1600)
                    }
                }
                HStack(spacing: 12) {
                    Button { model.back() } label: { Label("Back", systemImage: "arrow.left") }
                        .buttonStyle(.glass).pointerStyle(.link).disabled(index == 0)
                    Spacer()
                    Button { withAnimation(.smooth(duration: 0.2)) { model.deleteAndNext() } } label: {
                        Label("Delete", systemImage: "trash").frame(minWidth: 90)
                    }
                    .buttonStyle(.glassProminent).tint(.red).controlSize(.large).pointerStyle(.link)
                    .help("⌫ or D")
                    Button { withAnimation(.smooth(duration: 0.2)) { model.keepAndNext() } } label: {
                        Label("Keep", systemImage: "checkmark").frame(minWidth: 90)
                    }
                    .buttonStyle(.glassProminent).tint(.green).controlSize(.large).pointerStyle(.link)
                    .help("→ or K")
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.glass).pointerStyle(.link)
                }
                Text("→ keep · ⌫ delete · ← back").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(22)
        .frame(width: 820)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.rightArrow, "k"]) { _ in model.keepAndNext(); return .handled }
        .onKeyPress(keys: [.delete, .deleteForward, "d"]) { _ in model.deleteAndNext(); return .handled }
        .onKeyPress(keys: [.leftArrow]) { _ in model.back(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var finished: some View {
        let marked = model.reviewList.filter(model.isSelected)
        return VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("All reviewed").font(.title2.weight(.semibold))
            Text(marked.isEmpty ? "Nothing marked for deletion." : "\(marked.count) marked for deletion\(marked.compactMap(\.size).reduce(0, +) > 0 ? " (\(Fmt.bytes(marked.compactMap(\.size).reduce(0, +))))" : "").")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Back") { model.back() }.buttonStyle(.glass).pointerStyle(.link)
                Button("Done") { dismiss() }.buttonStyle(.glass).pointerStyle(.link)
                if !marked.isEmpty {
                    Button("Delete \(marked.count)…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { confirmDelete() }
                    }
                    .buttonStyle(.glassProminent).tint(.red).pointerStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}
