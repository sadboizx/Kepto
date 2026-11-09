import SwiftUI
import UIKit

/// Library: the app's home screen. Videos are watched in a TikTok-style
/// full-screen feed — one video at a time, full-width 9:16, swipe
/// up/down for the next — with a top bar (title + search + section
/// chips) overlaid on the video. The menu switches between Tất cả
/// (all) / Reels (videos) / Bài viết (images) / Collections. Collections
/// stay a grid (one card per creator username, like TikTok's
/// Collections tab); tapping a collection opens its videos in the feed.
/// Searching shows matching items in the feed instead.
/// Thumbnails are authenticated (AsyncImage cannot send the Authorization
/// header), so `AuthenticatedThumbnail` loads them with URLSession
/// (see `KeptoAPI.fetchThumbnail`) and keeps them in memory only.
struct LibraryView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var showingSettings = false
    @State private var searchTask: Task<Void, Never>?
    @State private var clipboardAlert = false
    /// URL-input alert (shown by the "+" menu's "Lưu link mới").
    @State private var showingURLInput = false
    @State private var urlInput = ""
    /// One-line notice after a direct save (e.g. "already saved").
    @State private var saveNotice: String?
    /// Whether the search field is shown in the feed's top bar.
    @State private var showingSearchField = false
    /// Resets the feed (back to the first video) after a new save.
    @State private var feedResetToken = UUID()

    private let collectionColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    /// True while the home shows the video feed (not the collections
    /// grid): the navigation bar is hidden and the top bar overlays
    /// the video, TikTok-style.
    private var isFeed: Bool {
        viewModel.isConfigured && (viewModel.selectedSection != .collections || viewModel.isSearching)
    }

    /// Identity for the feed view: a new identity discards the feed's
    /// scroll position and reopens it at the first video — when the
    /// section or search changes, and after a new save.
    private var feedID: String {
        "\(viewModel.selectedSection.rawValue)-\(viewModel.isSearching)-\(feedResetToken.uuidString)"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                if viewModel.isConfigured {
                    addButton
                }
            }
            .navigationTitle("Kepto")
            .toolbar(isFeed ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .onChange(of: viewModel.searchText) { _, _ in
                // Debounce: wait for the user to stop typing before
                // hitting the server with a new `q` query.
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    await viewModel.fetch()
                }
            }
            .task {
                await viewModel.selectSection(viewModel.selectedSection)
            }
            .onChange(of: viewModel.pendingShareURL) { _, newValue in
                // A link handed over by the Share Extension: save it
                // directly (no sheet) and clear the handoff.
                if let newValue {
                    viewModel.pendingShareURL = nil
                    Task { await saveDirect(newValue) }
                }
            }
            .alert("Lưu link", isPresented: $showingURLInput) {
                TextField("Dán link TikTok, Instagram…", text: $urlInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Lưu") {
                    let url = urlInput
                    urlInput = ""
                    Task { await saveDirect(url) }
                }
                Button("Hủy", role: .cancel) { urlInput = "" }
            }
            .alert("Kepto", isPresented: .constant(saveNotice != nil)) {
                Button("OK") { saveNotice = nil }
            } message: {
                Text(saveNotice ?? "")
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                viewModel.reloadConfig()
                Task { await viewModel.selectSection(viewModel.selectedSection) }
            }) {
                SettingsView()
            }
            .alert("Kepto", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("Clipboard", isPresented: $clipboardAlert) {
                Button("OK") {}
            } message: {
                Text("Clipboard không có link http(s) nào.")
            }
        }
    }

    /// Floating "+" button (bottom-right): opens a menu to save a new
    /// link, or save the link currently on the clipboard. Choosing
    /// either starts the save right away — no further sheet or menu.
    /// (No Photo Library entry: Kepto saves by link, it has no
    /// local-file upload.) It sits above the feed's bottom progress
    /// bar, so its bottom padding clears the bar.
    private var addButton: some View {
        Menu {
            Button {
                showingURLInput = true
            } label: {
                Label("Lưu link mới", systemImage: "link.badge.plus")
            }
            Button {
                Task { await saveDirectFromClipboard() }
            } label: {
                Label("Lưu từ Clipboard", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 64)
    }

    /// Saves a link right away, with no sheet in between. On success the
    /// home switches to Tất cả and the feed reopens at the top so the
    /// newly saved video is the first one shown; a duplicate shows a
    /// short notice instead of a second copy. A failure surfaces
    /// through the view model's error alert.
    private func saveDirect(_ rawURL: String) async {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let result = await viewModel.save(url: trimmed) else { return }
        await viewModel.selectSection(.all)
        if result.duplicate {
            saveNotice = "Link này đã lưu trước đó."
        } else {
            feedResetToken = UUID()
        }
    }

    /// Reads the first http(s) URL on the clipboard and saves it right
    /// away; warns when there is no link.
    private func saveDirectFromClipboard() async {
        guard let text = UIPasteboard.general.string,
              let url = Self.firstURL(in: text) else {
            clipboardAlert = true
            return
        }
        await saveDirect(url.absoluteString)
    }

    private static func firstURL(in text: String) -> URL? {
        let pattern = "https?://[^\\s\"'<>]+"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.isConfigured {
            setupView
        } else if viewModel.selectedSection == .collections && !viewModel.isSearching {
            collectionsContent
        } else {
            feedHome
        }
    }

    private var setupView: some View {
        ContentUnavailableView {
            Label("Set up Kepto", systemImage: "link.badge.plus")
        } description: {
            Text("Enter your Worker URL and API key in Settings to start saving.")
        } actions: {
            Button("Open Settings") { showingSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    /// The video feed home: full-screen black feed with the top bar
    /// (title + search + section chips) overlaid, TikTok-style.
    private var feedHome: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView("Loading…")
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.items.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptyIcon)
                    } description: {
                        Text(emptyDescription)
                    } actions: {
                        Button("Save a link") { showingURLInput = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    FeedView(
                        items: Binding(get: { viewModel.items }, set: { _ in }),
                        startItemId: viewModel.items.first?.id ?? "",
                        onNearEnd: { await viewModel.loadMore() }
                    )
                    .id(feedID)
                }
                feedTopOverlay(topSafeArea: geo.safeAreaInsets.top)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Top bar overlaid on the feed (TikTok-style): title + search and
    /// settings buttons, an optional search field, and the section
    /// chips — all on a top gradient so they stay legible over video.
    private func feedTopOverlay(topSafeArea: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Kepto")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showingSearchField = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal)
            if showingSearchField {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.7))
                    TextField("Search title, caption, @username", text: $viewModel.searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Button("Cancel") {
                        showingSearchField = false
                        viewModel.searchText = ""
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.45))
                .clipShape(Capsule())
                .padding(.horizontal)
                .padding(.top, 8)
            }
            sectionMenu
        }
        .padding(.top, topSafeArea)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Menu bar: Tất cả / Reels / Bài viết / Collections. Over the
    /// video: selected is a white capsule with black text (TikTok's
    /// selected tab), the rest are white text on a dark translucent
    /// capsule.
    private var sectionMenu: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibrarySection.allCases) { section in
                    let selected = viewModel.selectedSection == section
                    Button {
                        Task { await viewModel.selectSection(section) }
                    } label: {
                        Text(section.title)
                            .font(.subheadline)
                            .fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selected ? Color.white : Color.black.opacity(0.35))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// Collections grid (2 columns of square per-creator cards).
    /// Collections are cards, not videos, so they keep a grid — the
    /// feed is for watching videos; tapping a collection opens its
    /// videos in the feed.
    private var collectionsContent: some View {
        Group {
            if viewModel.collections.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("No collections yet", systemImage: "folder")
                } description: {
                    Text("Save a link and it will appear here grouped by its creator.")
                } actions: {
                    Button("Save a link") { showingURLInput = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: collectionColumns, spacing: 12) {
                        ForEach(viewModel.collections) { collection in
                            NavigationLink {
                                CollectionDetailView(collection: collection)
                            } label: {
                                CollectionCard(collection: collection)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await viewModel.fetchCollections()
                }
                .overlay {
                    if viewModel.isLoading && viewModel.collections.isEmpty {
                        ProgressView("Loading…")
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        if viewModel.isSearching { return "No matches" }
        switch viewModel.selectedSection {
        case .reels: return "No reels yet"
        case .posts: return "No posts yet"
        case .all, .collections: return "Nothing saved yet"
        }
    }

    private var emptyIcon: String {
        if viewModel.isSearching { return "magnifyingglass" }
        return "tray"
    }

    private var emptyDescription: String {
        if viewModel.isSearching { return "Nothing saved matches this search yet." }
        switch viewModel.selectedSection {
        case .reels: return "No saved videos yet — save a TikTok or Reels link."
        case .posts: return "No saved photos yet — save a photo post link."
        case .all, .collections: return "Tap + and paste a link from TikTok, Instagram, Threads, X, Facebook, Douyin, or YouTube."
        }
    }
}

/// One collection card (TikTok-style, measured from TikTok's Collections
/// tab): a SQUARE cover (1:1) with the name overlaid at the bottom — the
/// bookmark icon above the name, the lock at bottom-right — and no text
/// or count below the card. Side padding 16, gap 12, corner radius 12.
private struct CollectionCard: View {
    let collection: CollectionInfo

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let coverId = collection.coverItemId {
                AuthenticatedThumbnail(itemId: coverId)
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            // Bottom gradient so the white overlay text stays legible.
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(nameLine)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let handle = handleLine {
                        Text(handle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "lock")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            .padding(12)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var nameLine: String {
        if let author = collection.author, !author.isEmpty { return author }
        return collection.displayName
    }

    private var handleLine: String? {
        guard let username = collection.authorUsername, !username.isEmpty else { return nil }
        // When there is no display name, displayName already is @username.
        if collection.author == nil || collection.author?.isEmpty == true { return nil }
        return "(@\(username))"
    }
}

/// One video cell in the 3-column grid (TikTok profile style): a
/// vertical 9:16 cell with slightly rounded corners, so each cell stays
/// visibly distinct even when consecutive videos look alike. The
/// thumbnail fills the cell (a 9:16 video fits exactly; anything wider
/// is centre-cropped, like TikTok) and is clipped to the cell, so
/// nothing overflows. Badge bottom-left (play + view count, or duration),
/// a spinner while pending, and a red dot when ingest failed.
///
/// NOTE: kept for the collection detail page (a per-creator overview,
/// like a TikTok profile grid). The home screen itself no longer uses
/// a grid — videos are watched in the full-screen feed (FeedView).
struct VideoGridCell: View {
    let item: Item

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AuthenticatedThumbnail(item: item)
                .aspectRatio(9 / 16, contentMode: .fill)
                .clipped()
            if item.status == .pending {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView()
                        .tint(.white)
                }
            }
            if let badge = badgeText, item.status == .ready {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text(badge)
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                .padding(6)
            }
            if item.status == .failed {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var badgeText: String? {
        item.formattedViewCount ?? item.formattedDuration
    }
}

/// Status badge: pending shows a spinner (ingest still running), ready is
/// green, failed is red with the ingest error visible in the detail view.
struct StatusBadge: View {
    let status: ItemStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .pending {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(status.displayName)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .pending: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }
}

/// Thumbnail loaded with an authenticated URLSession request.
/// AsyncImage cannot send an Authorization header, so it cannot load
/// GET /api/thumb/:id at all — this view exists because of that.
/// The image is kept in memory only; nothing is written to disk.
struct AuthenticatedThumbnail: View {
    let itemId: String
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var image: UIImage?

    init(item: Item) {
        self.itemId = item.id
    }

    init(itemId: String) {
        self.itemId = itemId
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: itemId) {
            guard image == nil, let api = viewModel.api else { return }
            image = try? await api.fetchThumbnail(id: itemId)
        }
    }
}
