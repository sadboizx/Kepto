import SwiftUI
import UIKit

/// Which album section the "See All" page shows (Photos Albums
/// style: each section header has a "See All" button on the right).
enum AlbumSection: String, Hashable {
    case myAlbums
    case creators
}

/// Albums: the Photos-style Albums tab. Four sections, in Photos
/// order:
///  - "My Albums": Recents (all saved items), Favorites (hearted
///    items), then the user's own collections — a sideways-scrolling
///    2-row grid of square album cards (cover + name + count below,
///    like Photos iOS 17.4), with a "See All" button.
///  - "Creators": one card per TikTok creator whose collection was
///    saved — Photos' "People & Pets" slot, kept under the Creators
///    name (Q6), since Kepto has no sharing. Same 2-row grid +
///    See All.
///  - "Media Types": Videos / Photos rows (Photos style, Q6). No
///    Shared Albums section — Kepto has no sharing by design.
///  - "Utilities": Recently Deleted only (Option A — a note screen,
///    not a trash list: Kepto deletes are permanent).
/// A blue "+" at the top-left creates a new album (a user-created
/// collection). Tapping a card opens its videos in a square grid;
/// tapping a video there opens the feed. "See All" opens the whole
/// section as a 2-column grid. Edit mode lives ONLY on the See All
/// page (Photos behavior): red minus badges delete albums.
/// Long-press a card for the Photos album menu (Add Photos / Rename
/// Album / Delete Album on user albums; Delete Album only on
/// creators; nothing on Recents/Favorites/Media Types).
struct AlbumsView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    /// "New Album" name alert (from the "+" button).
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    /// Rename alert (from an album card's long-press menu).
    @State private var renamingCollection: MyCollection?
    @State private var renameText = ""
    @State private var saveNotice: String?
    /// Presents the Settings sheet from the "…" menu.
    @State private var showingSettings = false
    /// Edit mode lives ONLY on the See All page (Photos behavior):
    /// the Albums tab itself has no Edit button — tapping a card
    /// there always navigates. On See All, Edit shows red minus
    /// badges to delete albums.
    @State private var isEditingSeeAll = false
    /// The album awaiting delete confirmation from its red
    /// minus badge (nil = no confirmation open).
    @State private var albumPendingDelete: AlbumItem?
    @State private var showingDeleteAlbumConfirmation = false
    /// The section whose "See All" page is open (nil = closed).
    @State private var seeAllSection: AlbumSection?
    /// The Recently Deleted note screen (false = closed): Option A —
    /// a note, not a trash list.
    @State private var showingRecentlyDeleted = false
    /// The album whose detail page is open (nil = closed).
    /// Navigation is a Button + navigationDestination, NOT an inline
    /// NavigationLink in the LazyVGrid: inline links in a lazy grid
    /// are flaky on iOS 17 (some cards simply never navigate).
    @State private var selectedSource: AlbumSource?
    /// Pop-to-root request from the tab bar (KeptoTabView bumps
    /// this when the already-selected Albums tab is tapped again,
    /// round 3): the destinations above are driven by state, so
    /// clearing them pops the whole stack back to the Albums root.
    @Binding var popToRootRequest: Int

    /// 2-column album grid (Photos Albums tab): 12pt gaps.
    private let albumColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            mainScrollView()
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .navigationDestination(item: $selectedSource) { source in
                PhotoCollectionScreen(source: source)
            }
            .navigationDestination(item: $seeAllSection) { section in
                seeAllView(for: section)
            }
            // Recently Deleted (Option A): a note screen, not a
            // grid — Kepto has no trash.
            .navigationDestination(isPresented: $showingRecentlyDeleted) {
                RecentlyDeletedNoteView()
            }
            .task {
                await viewModel.fetchCollections()
                await viewModel.fetchStats()
                if viewModel.items.isEmpty {
                    await viewModel.fetch()
                }
            }
            .refreshable {
                await viewModel.fetchCollections()
                await viewModel.fetchStats()
            }
            .alert(L10n.newAlbum, isPresented: $showingNewCollection) {
                TextField(L10n.title, text: $newCollectionName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.save) {
                    let name = newCollectionName
                    newCollectionName = ""
                    Task {
                        if let created = await viewModel.createMyCollection(name: name) {
                            saveNotice = L10n.createdCollection(created.name)
                        }
                    }
                }
                // (No .disabled here: the v57.2 .disabled lagged
                // behind typing in the alert, so the first tap on
                // Save did nothing and creating an album took two
                // taps. The Worker already rejects an empty name
                // with a clear error.)
                Button(L10n.cancel, role: .cancel) { newCollectionName = "" }
            } message: {
                Text(L10n.newAlbumMessage)
            }
            // Rename alert (from an album card's long-press menu).
            // Photos style: the current name pre-filled, Save/Cancel.
            .alert(L10n.renameAlbum, isPresented: .constant(renamingCollection != nil)) {
                TextField(L10n.title, text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.save) {
                    guard let collection = renamingCollection else { return }
                    let name = renameText
                    renamingCollection = nil
                    renameText = ""
                    Task { await viewModel.renameMyCollection(collection, name: name) }
                }
                Button(L10n.cancel, role: .cancel) {
                    renamingCollection = nil
                    renameText = ""
                }
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
            // Delete confirmation for a red minus badge (Edit mode).
            // MyCollection: both choices (like the detail "…" menu).
            // Creator: only "Delete Album & Videos" — keeping the
            // videos would just make the creator album reappear.
            .confirmationDialog(
                L10n.deleteAlbumTitle(albumPendingDelete?.title ?? ""),
                isPresented: $showingDeleteAlbumConfirmation,
                titleVisibility: .visible
            ) {
                // NOTE: `if` / `else if`, NOT a `switch` — the
                // actions closure is a @ViewBuilder, and a `switch`
                // (especially one with a `break` for the .kind case)
                // is a control-flow statement ViewBuilder cannot use.
                if let album = albumPendingDelete {
                    if album.kind == .user {
                        Button(L10n.deleteAlbumAndVideos, role: .destructive) {
                            Task { await deleteAlbumCard(album, deleteItems: true) }
                        }
                        Button(L10n.deleteAlbumOnly, role: .destructive) {
                            Task { await deleteAlbumCard(album, deleteItems: false) }
                        }
                    } else if album.kind == .people {
                        Button(L10n.deleteAlbumAndVideos, role: .destructive) {
                            Task { await deleteAlbumCard(album, deleteItems: true) }
                        }
                    }
                    // .recents / .favorites / .media: no delete
                    // buttons — built-in albums and Media Types are
                    // not deletable.
                }
                Button(L10n.cancel, role: .cancel) { albumPendingDelete = nil }
            } message: {
                if let collection = pendingDeleteCreator {
                    Text(L10n.deleteCreatorMessage(collection.count))
                } else if let collection = pendingDeleteMyCollection {
                    Text(L10n.deleteAlbumMessage(collection.count))
                }
            }
        }
        // Back button ("< Albums") in the pushed detail views:
        // the back button's tint comes from the NavigationStack, NOT
        // from the pushed view — that is why .tint(.primary) on the
        // detail views did nothing in v41. The system back button
        // stays (so the swipe-back gesture works); hiding it with
        // .navigationBarBackButtonHidden broke the gesture in v42.
        // The "+" and "See All" buttons stay blue (explicit
        // .foregroundStyle(.blue)); the selection checkmark stays
        // blue (explicit .blue in PhotosGridCell).
        // Pop to root on a tab re-tap (round 3, see
        // popToRootRequest): clearing the destination states pops
        // the album detail, the See All page and the Recently
        // Deleted note alike — the viewer overlay inside the
        // detail unmounts with it.
        .onChange(of: popToRootRequest) { _, _ in
            selectedSource = nil
            seeAllSection = nil
            showingRecentlyDeleted = nil
            isEditingSeeAll = false
        }
        .tint(.primary)
    }

    /// The Albums root list: the four sections (My Albums, Creators,
    /// Media Types, Utilities) in a ScrollView. Extracted from `body` — the
    /// whole body was too large for the compiler to type-check in
    /// reasonable time.
    private func mainScrollView() -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    albumSection(title: L10n.myAlbums, items: myAlbumItems) {
                        seeAllSection = .myAlbums
                    }
                    albumSection(title: L10n.creators, items: creatorItems) {
                        seeAllSection = .creators
                    }
                    mediaTypesSection()
                    utilitiesSection()
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .navigationTitle(L10n.albums)
            // Transparent status bar / nav bar: the sections show
            // through under the status bar and the title, no solid
            // band.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Photos behavior: tapping "+" opens a menu with
                    // "New Album" (not the name alert directly) —
                    // the same menu the See All Edit "+" shows.
                    Menu {
                        Button {
                            showingNewCollection = true
                        } label: {
                            Label(L10n.newAlbum, systemImage: "square.stack")
                        }
                    } label: {
                        // Photos uses a thin "+" here — regular
                        // weight, not semibold (semibold looks too
                        // thick next to the title).
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(.blue)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The "…" menu lives on every tab except the
                    // Player: Paste from Clipboard, Photo Library,
                    // Choose Files, Settings. (No Edit button here —
                    // Edit lives only on See All.)
                    Menu {
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
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .accessibilityLabel(L10n.moreOptions)
                    }
                }
            }
    }

    /// The See All page for one section: the whole section as a
    /// 2-column grid of album cards (Photos style). Extracted from
    /// `body` for the same type-check reason as mainScrollView.
    private func seeAllView(for section: AlbumSection) -> some View {
                ScrollView {
                    LazyVGrid(columns: albumColumns, spacing: 16) {
                        ForEach(section == .myAlbums ? myAlbumItems : creatorItems, id: \.self) { album in
                            // The minus badge is a SIBLING of the card
                            // button (not inside it): the card button
                            // is disabled in Edit mode, which would
                            // also disable a badge nested inside it.
                            ZStack(alignment: .topLeading) {
                                Button { select(album) } label: {
                                    albumTile(album)
                                }
                                .buttonStyle(.plain)
                                .disabled(isEditingSeeAll)
                                // Long-press menu (Photos) — hidden in
                                // Edit mode (the minus badge is the
                                // delete path there) and on
                                // Recents/Favorites (not deletable).
                                .contextMenu {
                                    if !isEditingSeeAll, isDeletable(album) {
                                        albumContextMenu(for: album)
                                    }
                                }
                                // Red minus badge (Photos Edit mode).
                                // Only on deletable albums.
                                if isEditingSeeAll, isDeletable(album) {
                                    Button {
                                        albumPendingDelete = album
                                        showingDeleteAlbumConfirmation = true
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(.red)
                                            .background(Color.white, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: -8, y: -8)
                                }
                            }
                        }
                    }
                    .padding()
                }
                // Native interactive pop gesture (swipe back): the
                // grid ScrollView would otherwise swallow the left
                // edge pan, like the Player before v46. This also
                // keeps swipe-back working while the back button is
                // hidden in Edit mode (below) — the bridge re-enables
                // the gesture and permits it whenever there is a
                // view to pop to.
                .background(NativePopGestureHelper())
                .navigationTitle(section == .myAlbums ? L10n.myAlbums : L10n.creators)
                // Photos: in Edit mode the "< Albums" back button
                // becomes a "+" that opens the New Album menu. The
                // button is hidden only while editing.
                .navigationBarBackButtonHidden(isEditingSeeAll)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Only in Edit mode — otherwise the system
                        // back button ("< Albums") shows.
                        if isEditingSeeAll {
                            Menu {
                                Button {
                                    showingNewCollection = true
                                } label: {
                                    Label(L10n.newAlbum, systemImage: "rectangle.stack.badge.plus")
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Photos-style Edit mode for this See All page.
                        // "Edit" is body size (17pt) like Photos, and
                        // "Done" is bold.
                        Button(isEditingSeeAll ? L10n.done : L10n.edit) {
                            isEditingSeeAll.toggle()
                        }
                        .font(.body)
                        .fontWeight(isEditingSeeAll ? .bold : .regular)
                        .foregroundStyle(.blue)
                    }
                }
    }

    /// "My Albums" rows: Recents, Favorites, then the user's own
    /// collections.
    private var myAlbumItems: [AlbumItem] {
        var items: [AlbumItem] = [
            AlbumItem(id: "recents", title: L10n.recents, count: recentsCount,
                      coverID: viewModel.items.first?.id, kind: .recents,
                      symbol: "clock", tint: .gray, collectionID: nil),
            AlbumItem(id: "favorites", title: L10n.favorites, count: favoritesCount,
                      coverID: favoritesCoverID,
                      kind: .favorites, symbol: "heart", tint: .red, collectionID: nil),
        ]
        items += viewModel.myCollections.map { collection in
            AlbumItem(id: "my:\(collection.id)", title: myCollectionDisplayName(collection),
                      count: collection.count, coverID: collection.coverItemId,
                      kind: .user, symbol: "square.stack", tint: .blue,
                      collectionID: collection.id)
        }
        return items
    }

    /// "Creators" rows: one per TikTok creator whose collection
    /// was saved.
    private var creatorItems: [AlbumItem] {
        viewModel.collections.map { collection in
            AlbumItem(id: "creator:\(collection.id)", title: collection.displayName,
                      count: collection.count, coverID: collection.coverItemId,
                      kind: .people, symbol: "person", tint: .gray,
                      collectionID: collection.id)
        }
    }

    /// "Media Types" rows: Videos / Photos (Q6). Counts come from
    /// /api/stats when available, else from the full metadata cache.
    private var mediaItems: [AlbumItem] {
        let videos = viewModel.libraryStats?.videos
            ?? viewModel.allMetadata.filter { $0.contentType?.hasPrefix("video/") == true }.count
        let photos = viewModel.libraryStats?.photos
            ?? viewModel.allMetadata.filter { $0.contentType?.hasPrefix("image/") == true }.count
        return [
            AlbumItem(id: "media:video", title: L10n.videos, count: videos,
                      coverID: viewModel.allMetadata.first { $0.contentType?.hasPrefix("video/") == true }?.id,
                      kind: .media, symbol: "video", tint: .blue, collectionID: nil),
            AlbumItem(id: "media:photo", title: L10n.photos, count: photos,
                      coverID: viewModel.allMetadata.first { $0.contentType?.hasPrefix("image/") == true }?.id,
                      kind: .media, symbol: "photo", tint: .green, collectionID: nil),
        ]
    }

    /// User albums show as-is (their stored names); Recents /
    /// Favorites keep their Title Case. The app's own "Imports"
    /// album is the exception — it always shows as "Imports" with
    /// a capital I, whatever case the stored name has.
    private func myCollectionDisplayName(_ collection: MyCollection) -> String {
        collection.name.localizedCaseInsensitiveCompare("Imports") == .orderedSame
            ? "Imports"
            : collection.name
    }

    /// Two rows for the horizontal grids (Photos Albums style: each
    /// section scrolls sideways and is at most 2 rows tall).
    private var albumRows: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    /// Card width in the horizontal grids: two full cards plus a
    /// peek of the next one fit on screen, like Photos.
    private var albumCardWidth: CGFloat {
        (UIScreen.main.bounds.width - 44) / 2
    }

    /// One section (My Albums / Creators): a header with a "See All"
    /// button on the right, then a sideways-scrolling 2-row grid of
    /// album cards. Swipe sideways to see more albums. Tapping a
    /// card navigates to it — there is no Edit mode on this screen
    /// (Photos: Edit lives only on the See All page).
    private func albumSection(title: String, items: [AlbumItem], onSeeAll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    // PhotosClone section header (native insetGrouped
                    // List style): small, uppercase, secondary gray.
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(L10n.seeAll, action: onSeeAll)
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: albumRows, spacing: 12) {
                    ForEach(items, id: \.self) { album in
                        // No Edit mode on the Albums tab itself
                        // (Photos: Edit lives only on the See All
                        // page) — a tap always navigates. Long-press
                        // shows the Photos album menu (Add Photos /
                        // Rename / Delete) on user + creator albums;
                        // Recents/Favorites/Media Types have no menu.
                        // The menu is on the Button itself (not the
                        // card label) — a contextMenu on a Button's
                        // label does not fire reliably.
                        Button { select(album) } label: {
                            albumTile(album)
                                .frame(width: albumCardWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if isDeletable(album) {
                                albumContextMenu(for: album)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// The Media Types section: Photos-style utility rows (Videos /
    /// Photos), no "See All" — there are only two rows. Tapping a
    /// row opens the media-filtered browser.
    private func mediaTypesSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.mediaTypes)
                // PhotosClone section header (native insetGrouped
                // List style): small, uppercase, secondary gray.
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)
            VStack(spacing: 0) {
                ForEach(mediaItems, id: \.self) { album in
                    Button { select(album) } label: {
                        utilityRow(album)
                    }
                    .buttonStyle(.plain)
                    if album.id != mediaItems.last?.id {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    /// The Utilities section: Recently Deleted only (Option A — a
    /// note screen, not a trash list). Same header style as Media
    /// Types; the row is the shared `utilityRow` (trash icon, red
    /// tint like PhotosClone, no count).
    private func utilitiesSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.utilities)
                // PhotosClone section header (native insetGrouped
                // List style): small, uppercase, secondary gray.
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)
            VStack(spacing: 0) {
                Button { showingRecentlyDeleted = true } label: {
                    utilityRow(recentlyDeletedItem)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
    }

    /// The Recently Deleted row: trash icon, red tint (PhotosClone),
    /// no count, no cover — the note screen has nothing to list.
    private var recentlyDeletedItem: AlbumItem {
        AlbumItem(id: "utilities:deleted", title: L10n.recentlyDeleted, count: 0,
                  coverID: nil, kind: .deleted, symbol: "trash", tint: .red,
                  collectionID: nil)
    }

    /// One album card (Photos' `albumTile`): a SQUARE cover (1:1,
    /// centre-cropped, slightly rounded corners) with the name and
    /// the item count BELOW the card — not overlaid on it. The
    /// Favorites cover is the newest favorite's media thumbnail,
    /// like any other album (round 5 — the white heart badge is
    /// gone). Without a cover, the card shows the album symbol in
    /// its tint color (the heart is the Favorites empty state).
    private func albumTile(_ album: AlbumItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                if let cover = album.coverID {
                    AspectThumbnail(itemId: cover)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: album.symbol)
                        .font(.title2)
                        .foregroundStyle(album.tint.color)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(album.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(itemCountText(album.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // The tappable region is exactly this card's bounds: a tap
        // on the bottom edge must open this album, not the one below
        // it.
        .contentShape(Rectangle())
    }

    /// One Media Types row (Photos' `utilityRow`): a gradient icon
    /// tile, the title, and the item count on the right.
    private func utilityRow(_ album: AlbumItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(album.tint.color.gradient)
                Image(systemName: album.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            Text(album.title)
                .foregroundStyle(.primary)
            Spacer()
            // PhotosClone: the Recently Deleted row shows no count.
            Text(album.kind == .deleted ? "" : itemCountText(album.count))
                .foregroundStyle(.secondary)
                .font(.body)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func itemCountText(_ count: Int) -> String {
        L10n.itemsCount(count)
    }

    /// Whether an album can be deleted from Edit mode. Recents,
    /// Favorites and Media Types are built-in and cannot be deleted;
    /// user albums and creator albums can.
    private func isDeletable(_ album: AlbumItem) -> Bool {
        switch album.kind {
        case .user, .people: return true
        case .recents, .favorites, .media, .deleted: return false
        }
    }

    /// The creator behind a pending delete (for the confirmation
    /// message), looked up from the ViewModel by username.
    private var pendingDeleteCreator: CollectionInfo? {
        guard let album = albumPendingDelete, album.kind == .people,
              let id = album.collectionID else { return nil }
        return viewModel.collections.first { $0.id == id }
    }

    /// The user collection behind a pending delete (for the
    /// confirmation message), looked up from the ViewModel by id.
    private var pendingDeleteMyCollection: MyCollection? {
        guard let album = albumPendingDelete, album.kind == .user,
              let id = album.collectionID else { return nil }
        return viewModel.myCollections.first { $0.id == id }
    }

    /// Delete the album from its red minus badge (Edit mode).
    /// MyCollection: the same two choices as the detail "…" menu
    /// (Delete Album & Videos / Delete Album Only). Creator: only
    /// "Delete Album & Videos" — keeping the videos would just make
    /// the creator album reappear.
    private func deleteAlbumCard(_ album: AlbumItem, deleteItems: Bool) async {
        switch album.kind {
        case .user:
            guard let id = album.collectionID else { return }
            do {
                try await viewModel.deleteMyCollection(id: id, deleteItems: deleteItems)
            } catch {
                viewModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .people:
            guard let id = album.collectionID else { return }
            do {
                // collectionID is the username, or "__unknown__" for
                // the NULL-username creator — the Worker handles both.
                try await viewModel.deleteCreatorCollection(username: id)
            } catch {
                viewModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .recents, .favorites, .media, .deleted:
            break
        }
    }

    /// The long-press menu on an album card (Photos): Add Photos /
    /// Rename Album / Delete Album on a user album; Delete Album
    /// only on a creator album (a creator album is derived from its
    /// videos, so it can't be renamed or added to).
    @ViewBuilder
    private func albumContextMenu(for album: AlbumItem) -> some View {
        if album.kind == .user, let id = album.collectionID,
           let collection = viewModel.myCollections.first(where: { $0.id == id }) {
            Button {
                viewModel.addPhotos(to: collection)
            } label: {
                Label(L10n.addPhotos, systemImage: "plus")
            }
            Button {
                renamingCollection = collection
                renameText = collection.name
            } label: {
                Label(L10n.renameAlbum, systemImage: "pencil")
            }
            Button(role: .destructive) {
                albumPendingDelete = album
                showingDeleteAlbumConfirmation = true
            } label: {
                Label(L10n.deleteAlbum, systemImage: "trash")
            }
        } else if album.kind == .people {
            Button(role: .destructive) {
                albumPendingDelete = album
                showingDeleteAlbumConfirmation = true
            } label: {
                Label(L10n.deleteAlbum, systemImage: "trash")
            }
        }
    }

    /// Opens the tapped album's detail page (one browser for every
    /// album kind — see `AlbumSource`).
    private func select(_ album: AlbumItem) {
        switch album.kind {
        case .recents, .favorites:
            selectedSource = .kind(album.kind)
        case .user:
            if let id = album.collectionID,
               let collection = viewModel.myCollections.first(where: { $0.id == id }) {
                selectedSource = .myCollection(collection)
            }
        case .people:
            if let id = album.collectionID,
               let collection = viewModel.collections.first(where: { $0.id == id }) {
                selectedSource = .creator(collection)
            }
        case .media:
            selectedSource = .media(album.id == "media:video" ? .video : .photo)
        case .deleted:
            // The Utilities row navigates to its note screen directly
            // (showingRecentlyDeleted), never through select().
            break
        }
    }

    /// Recents count: the real total from /api/stats when available,
    /// else the number of items loaded so far.
    private var recentsCount: Int {
        viewModel.libraryStats?.total ?? viewModel.items.count
    }

    /// Favorites count: from /api/stats when available, else the
    /// favorited items among the loaded ones.
    private var favoritesCount: Int {
        viewModel.libraryStats?.favorites ?? viewModel.items.filter(\.isFavorite).count
    }

    /// Favorites cover: the NEWEST favorited item's thumbnail. The
    /// full metadata cache (listAll) is the source — the paged
    /// Library list only holds the newest 50 items, so a favorite
    /// older than that never resolved and the card fell back to the
    /// heart symbol. Falls back to the paged list while the cache
    /// is still loading; nil (heart placeholder) when there are no
    /// favorites at all.
    private var favoritesCoverID: String? {
        viewModel.allMetadata.first(where: { $0.isFavorite })?.id
            ?? viewModel.items.first(where: { $0.isFavorite })?.id
    }
}

/// Recently Deleted, note-only (Option A): Kepto has no trash —
/// deletes are permanent, so there is nothing to list. The screen
/// says so plainly and points at the system Photos Recently Deleted
/// album for photos saved to the device. No grid, no Worker/D1
/// changes, no change to the delete flow. The note is vertically
/// centred (round 5); swipe-back works via NativePopGestureHelper
/// (same fix as the See All grid — the ScrollView would otherwise
/// swallow the left edge pan).
private struct RecentlyDeletedNoteView: View {
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                Text(L10n.recentlyDeletedNote)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    // minHeight + default centre alignment: a short
                    // note sits in the middle of the screen; a long
                    // note grows past minHeight and scrolls from
                    // the top like a normal ScrollView.
                    .frame(minHeight: geo.size.height)
            }
            .background(NativePopGestureHelper())
        }
        .navigationTitle(L10n.recentlyDeleted)
        .navigationBarTitleDisplayMode(.inline)
    }
}
