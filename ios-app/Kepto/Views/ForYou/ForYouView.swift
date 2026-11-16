import SwiftUI

/// For You tab, ported from Photos' `ForYouView` (sadboizx/Photos,
/// `Photos/Views/ForYou/ForYouView.swift`) onto Kepto data.
///
/// Photos structure kept: a `NavigationStack` with a Memories
/// carousel (cards with title + subtitle over a gradient) and a
/// Featured horizontal strip, section titles in Photos style
/// (`.title3` bold) and the same `emptyCard` helper.
/// Kepto differences (no PhotoKit data source):
/// - Memories come from the step-1 `viewModel.memories` (month
///   >= 8 items, max 8, month-only title — decision Q7); Featured
///   from `viewModel.featuredMetadata` (favorites <= 24, else the
///   16 newest). Cards are 16:9 like Kepto's old Memories cards
///   (Photos' are portrait 260x360). No Shared Activity section
///   and no People & Pets row — Kepto has no sharing, and Creators
///   live in the Albums tab.
/// - Tapping a memory or featured item resolves the full `Item`s
///   (page cache + fetch by id, same as the Search tab) and opens
///   the current feed viewer, scoped to that memory / the featured
///   list. Step 7 replaces the viewer with Photos' detail viewer,
///   which takes ids directly.
/// - The "…" menu (Import from Photos / Paste Clipboard / Settings)
///   stays on the tab like the other ported tabs.
/// - No L10n yet (step 9): strings are inline like the rest of
///   Kepto, and will be swapped to `L10n.*` then.
struct ForYouView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var feedItems: [Item] = []
    @State private var feedStartItem: Item?
    /// Presents the Settings sheet from the "…" menu.
    @State private var showingSettings = false
    /// Notice after a "…" Clipboard save (nil = no notice showing).
    @State private var saveNotice: String?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.items.isEmpty && viewModel.allMetadata.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.nothingSavedYet, systemImage: "heart.text.square")
                    } description: {
                        Text(L10n.forYouEmptyHint)
                    }
                    .padding(.top, 40)
                } else {
                    content
                }
            }
            .navigationTitle(L10n.forYou)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // The "…" menu lives on every tab except the
                    // Player: Clipboard, then Settings.
                    Menu {
                        Button { viewModel.showingPhotoPicker = true } label: {
                            Label(L10n.importFromPhotos, systemImage: "photo.on.rectangle")
                        }
                        Button {
                            Task {
                                if let notice = await viewModel.saveFromClipboard() {
                                    saveNotice = notice
                                } else {
                                    saveNotice = L10n.clipboardNoLink
                                }
                            }
                        } label: {
                            Label(L10n.pasteClipboard, systemImage: "doc.on.clipboard")
                        }
                        Button { showingSettings = true } label: {
                            Label(L10n.settings, systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20))
                            .accessibilityLabel(L10n.moreOptions)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .navigationDestination(item: $feedStartItem) { startItem in
                PhotoDetailView(items: $feedItems, startItemId: startItem.id, title: L10n.forYou)
            }
            .alert("Kepto", isPresented: .constant(saveNotice != nil)) {
                Button("OK") { saveNotice = nil }
            } message: {
                Text(saveNotice ?? "")
            }
            .alert("Kepto", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .refreshable {
                await viewModel.fetch()
            }
            .task {
                if viewModel.items.isEmpty {
                    await viewModel.fetch()
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                memoriesSection
                featuredSection
            }
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.memories)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
            if viewModel.memories.isEmpty {
                emptyCard(L10n.noMemoriesYet)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(viewModel.memories, id: \.key) { memory in
                            if let first = memory.items.first {
                                Button {
                                    openMemory(memory.items)
                                } label: {
                                    memoryCard(
                                        cover: first,
                                        title: Self.monthFormatter.string(from: memory.key),
                                        subtitle: L10n.itemsCount(memory.items.count)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func memoryCard(cover: ItemMetadata, title: String, subtitle: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            AspectThumbnail(itemId: cover.id, ratio: 16 / 9)
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(width: 300, height: 300 * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.featured)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
            if viewModel.featuredMetadata.isEmpty {
                emptyCard(L10n.noFeaturedYet)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.featuredMetadata, id: \.id) { meta in
                            Button {
                                openFeatured(meta)
                            } label: {
                                AssetThumbnail(source: meta, cornerRadius: 12)
                                    .frame(width: 132, height: 132)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// Open a memory in the current feed viewer: resolve the
    /// month's items to full Items (page cache + fetch by id, same
    /// as the Search tab) so the viewer can page through that
    /// month, then start at the first. Step 7 replaces the viewer
    /// with Photos' detail viewer, which takes ids directly.
    private func openMemory(_ items: [ItemMetadata]) {
        Task {
            feedItems = await viewModel.resolveItems(Array(items.prefix(50)))
            feedStartItem = feedItems.first
        }
    }

    /// Open a featured item in the current feed viewer: resolve
    /// the featured list so the viewer can page through it, then
    /// start at the tapped one. Same resolver as the Search tab.
    private func openFeatured(_ meta: ItemMetadata) {
        let matches = viewModel.featuredMetadata
        Task {
            feedItems = await viewModel.resolveItems(Array(matches.prefix(50)))
            feedStartItem = feedItems.first { $0.id == meta.id }
        }
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}
