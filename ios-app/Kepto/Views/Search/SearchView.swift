import SwiftUI

/// Search tab, ported from Photos' `SearchView` (sadboizx/Photos,
/// `Photos/Views/Search/SearchView.swift`) onto Kepto data.
///
/// Photos structure kept: a `NavigationStack` with a native
/// `.searchable` field, a Categories grid + a People row when idle,
/// and a results grid while searching. Kepto differences (no
/// PhotoKit data source):
/// - Search is SYNCHRONOUS over the step-1 `allMetadata` cache
///   (`viewModel.searchLocal`) — no debounce, no server round trip
///   (decisions Q8/Q8b). While the cache is empty the categories
///   fall back to the loaded pages.
/// - Categories are platforms (TikTok, Instagram, Facebook, Threads,
///   X, Douyin, YouTube, Albums) with the platform's newest item as
///   cover; People are the top 8 creators. No Places, no Moments —
///   Kepto items have no location data.
/// - Results are `ItemMetadata` rendered with the step-2
///   `AssetThumbnail`; tapping one resolves the full `Item`s
///   (page cache + fetch by id, same as the Library tab) and opens
///   the current feed viewer. Step 7 replaces the viewer with the
///   Photos detail viewer, which takes ids directly.
/// - No L10n yet (step 9): strings are inline like the rest of
///   Kepto, and will be swapped to `L10n.*` then.
/// - No long-press context menu on results (Photos has none); all
///   item actions live in the viewer.
struct SearchView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var query = ""
    @State private var selectedPlatform: Platform?
    @State private var feedItems: [Item] = []
    @State private var feedStartItem: Item?
    /// Presents the Settings sheet from the "…" menu.
    @State private var showingSettings = false

    /// 3-column square grid (Photos style): 2pt gaps.
    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    /// True when a text query or a platform category is active.
    private var isSearching: Bool {
        !trimmedQuery.isEmpty || selectedPlatform != nil
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Synchronous local matches over the full metadata cache.
    /// Recomputed on every keystroke — the cache is in memory, so
    /// there is no debounce and no network search.
    private var results: [ItemMetadata] {
        viewModel.searchLocal(query: trimmedQuery.isEmpty ? nil : trimmedQuery, platform: selectedPlatform)
    }

    /// Round-31: re-tap counter from the tab bar (KeptoTabView
    /// bumps it when the already-selected Search tab is tapped).
    @Binding var retapRequest: Int

    init(retapRequest: Binding<Int> = .constant(0)) {
        _retapRequest = retapRequest
    }

    /// Whether the native search field is active/focused
    /// (round-31): a re-tap on the Search tab sets this, which
    /// focuses the field and opens the keyboard. The query text
    /// is untouched — only focus changes.
    @State private var isSearchPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    resultsContent
                } else {
                    suggestions
                }
            }
            .navigationTitle(L10n.search)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, isPresented: $isSearchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Photos, People, Places…")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // The "…" menu lives on every tab except the
                    // Player: Paste from Clipboard, Photo Library,
                    // Choose Files, Settings.
                    Menu {
                        Button {
                            Task {
                                if let notice = await viewModel.saveFromClipboard() {
                                    viewModel.showToast(notice)
                                } else {
                                    viewModel.showToast("Không có link trên clipboard.", isError: true)
                                }
                            }
                        } label: {
                            Label(L10n.pasteClipboard, systemImage: "doc.on.clipboard")
                        }
                        Button { viewModel.showingPhotoPicker = true } label: {
                            Label(L10n.photoLibrary, systemImage: "photo.on.rectangle")
                        }
                        Button { viewModel.showingDocumentPicker = true } label: {
                            Label(L10n.chooseFiles, systemImage: "folder")
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
            // Round 7: hide the status bar + navigation bar while
            // the viewer overlay is open — the viewer's own
            // .statusBarHidden does not work in the overlay context.
            // Both are state-driven, so they return instantly when
            // the viewer closes (feedStartItem = nil).
            .toolbar(feedStartItem == nil ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(feedStartItem != nil)
            // Round-31: re-tap on the Search tab — focus the search
            // field (keyboard opens, text untouched). Guarded while
            // the viewer is open: the nav bar (and its search field)
            // is hidden then, so focusing would do nothing visible.
            .onChange(of: retapRequest) { _, _ in
                if feedStartItem == nil { isSearchPresented = true }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            // Viewer as a full-screen OVERLAY over these results,
            // not a push — see PhotoDetailView's header comment.
            .overlay {
                if let startItem = feedStartItem {
                    PhotoDetailView(items: $feedItems, startItemId: startItem.id, title: L10n.search, onDismiss: { feedStartItem = nil })
                        .ignoresSafeArea()
                }
            }
            .alert("Kepto", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .task {
                if viewModel.items.isEmpty {
                    await viewModel.fetch()
                }
            }
        }
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !platformCategories.isEmpty {
                    categoryRow
                }
                if !people.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.people)
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(people, id: \.name) { person in
                                    Button {
                                        query = person.name
                                    } label: {
                                        VStack(spacing: 6) {
                                            AssetThumbnail(source: person.cover, cornerRadius: 34, showBadge: false, showFavoriteMark: false)
                                                .frame(width: 68, height: 68)
                                                .clipShape(Circle())
                                            Text(person.name).font(.caption).lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                if platformCategories.isEmpty && people.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.nothingSavedYet, systemImage: "magnifyingglass")
                    } description: {
                        Text(L10n.saveLinksHint)
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.categories)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                ForEach(platformCategories, id: \.platform) { category in
                    SearchCategoryCard(
                        title: category.platform.displayName,
                        cover: category.cover
                    ) {
                        selectedPlatform = selectedPlatform == category.platform ? nil : category.platform
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var resultsContent: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView {
                    Label(L10n.noResults, systemImage: "magnifyingglass")
                } description: {
                    Text(trimmedQuery.isEmpty ? (selectedPlatform?.displayName ?? "") : trimmedQuery)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let platform = selectedPlatform {
                            // Selected-platform chip: the only way to
                            // clear the platform, since the categories
                            // hide while results are shown.
                            Button {
                                selectedPlatform = nil
                            } label: {
                                HStack(spacing: 6) {
                                    Text(platform.displayName)
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        }
                        LazyVGrid(columns: gridColumns, spacing: 2) {
                            ForEach(results) { meta in
                                Button {
                                    openResult(meta)
                                } label: {
                                    // Round 7: duration badge back on
                                    // Search results (round 3 hid it;
                                    // Categories / People hide it now).
                                    AssetThumbnail(source: meta)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
    }

    /// Open a result in the current feed viewer: resolve the current
    /// matches to full Items (page cache + fetch by id, same as the
    /// Library tab) so the viewer can page through them, then start
    /// at the tapped one. Step 7 replaces the viewer with Photos'
    /// detail viewer, which takes ids directly.
    private func openResult(_ meta: ItemMetadata) {
        let matches = results
        Task {
            feedItems = await viewModel.resolveItems(Array(matches.prefix(50)))
            feedStartItem = feedItems.first { $0.id == meta.id }
        }
    }

    // MARK: - Categories

    /// One category per platform that has saved items (cover = the
    /// platform's newest saved item). Prefers the full metadata
    /// cache; falls back to the loaded pages while listAll has not
    /// finished (or failed — e.g. Worker not deployed yet). Both
    /// sources are newest-first, so `first` is the newest item.
    private var platformCategories: [(platform: Platform, cover: any GridItemSource)] {
        if viewModel.allMetadataLoaded {
            var result: [(platform: Platform, cover: any GridItemSource)] = []
            for platform in Platform.allCases {
                if let first = viewModel.allMetadata.first(where: { $0.platform == platform }) {
                    result.append((platform: platform, cover: first))
                }
            }
            return result
        }
        var result: [(platform: Platform, cover: any GridItemSource)] = []
        for platform in Platform.allCases {
            if let first = viewModel.items.first(where: { $0.platform == platform }) {
                result.append((platform: platform, cover: first))
            }
        }
        return result
    }

    /// The most-saved creators (up to 8), cover = the creator's
    /// newest saved item. Same source rule as platformCategories.
    private var people: [(name: String, cover: any GridItemSource)] {
        if viewModel.allMetadataLoaded {
            return topCreators(from: viewModel.allMetadata.map { (name: $0.collectionName, cover: $0 as any GridItemSource) })
        }
        return topCreators(from: viewModel.items.map { (name: $0.collectionName, cover: $0 as any GridItemSource) })
    }

    private func topCreators(from pairs: [(name: String, cover: any GridItemSource)]) -> [(name: String, cover: any GridItemSource)] {
        var counts: [String: (count: Int, first: any GridItemSource)] = [:]
        for pair in pairs {
            if var entry = counts[pair.name] {
                entry.count += 1
                counts[pair.name] = entry
            } else {
                counts[pair.name] = (count: 1, first: pair.cover)
            }
        }
        return counts
            .map { (name: $0.key, cover: $0.value.first, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { (name: $0.name, cover: $0.cover) }
    }
}

/// One search category card (Photos Search style): a square cover
/// with the category name below it. The cover is any grid source —
/// light metadata when the full cache is loaded, a full Item while
/// falling back to the loaded pages. Moved from LibraryView.swift
/// (step 5) with the ported SearchView.
private struct SearchCategoryCard: View {
    let title: String
    let cover: (any GridItemSource)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let cover {
                        AssetThumbnail(source: cover, cornerRadius: 12, showBadge: false)
                    } else {
                        Color(.systemGray5)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
