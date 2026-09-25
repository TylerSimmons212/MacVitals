import SwiftUI

/// Toolbar ⓘ button that opens the plain-language guide for the current page.
struct GuideButton: View {
    let section: DashboardSection
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Understand this page", systemImage: "info.circle")
        }
        .pointerStyle(.link)
        .help("Understand this page")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            GuideView(guide: SectionGuide.for(section))
        }
    }
}

struct GuideView: View {
    let guide: SectionGuide

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(guide.title).font(.title3.weight(.semibold))
                    Text(guide.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                block("What healthy looks like", icon: "checkmark.circle.fill", tint: .green, items: guide.healthy)
                block("Common culprits", icon: "exclamationmark.triangle.fill", tint: .orange, items: guide.culprits)
                block("What you can do", icon: "wrench.and.screwdriver.fill", tint: .blue, items: guide.fixes)
                if !guide.glossary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Terms on this page", systemImage: "character.book.closed.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(guide.glossary) { term in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(term.term).font(.callout.weight(.semibold))
                                Text(term.meaning)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 380)
        .frame(maxHeight: 560)
    }

    @ViewBuilder
    private func block(_ title: String, icon: String, tint: Color, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.tertiary).frame(width: 4, height: 4)
                        Text(item)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
