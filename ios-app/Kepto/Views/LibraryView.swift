import SwiftUI

/// Library: the app's home screen. Home is collections — one per creator
/// username, like TikTok's Collections tab (cover thumbnail, @username,
/// video count). Tapping a collection opens its 3-column video grid.
/// Searching shows a flat grid of matching items instead.
/// Thumbnails are authenticated (AsyncImage cannot send the Authorization
/// header), so `AuthenticatedThumbnail` loads them with URLSession
/// (see `KeptoAPI.fetchThumbnail`) and keeps them in memory only.
struct LibraryView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var showingSave = false
    @State private var showingSettings = false
    @State private var searchTask: Task<Void, Never>?
    @State private var incomingShareURL: String?

    private let collectionColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]
    private let videoColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Kepto")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSave = true
                        } label: {
                            Label("Save", systemImage: "plus")
                        }
                    }
                }
                .searchable(text: $viewModel.searchText, prompt: "Search title, caption, @username")
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
                .refreshable {
                    if viewModel.isSearching {
                        await viewModel.fetch()
                    } else {
                        await viewModel.fetchCollections()
                    }
                }
                .task {
                    await viewModel.fetchCollections()
                }
                .onChange(of: viewModel.pendingShareURL) { _, newValue in
                    // A link handed over by the Share Extension: open the
                    // Save sheet for it (auto-save on appear).
                    if let newValue { incomingShareURL = newValue }
                }
                .sheet(isPresented: $showingSave) {
                    SaveView()
                }
                .sheet(isPresented: .constant(incomingShareURL != nil), onDismiss: {
                    incomingShareURL = nil
                    viewModel.pendingShareURL = nil
                }) {
                    SaveView(initialURL: incomingShareURL ?? "", autoSave: true)
                }
                .sheet(isPresented: $showingSettings, onDismiss: {
                    viewModel.reloadConfig()
                    Task { await viewModel.fetchCollections() }
                }) {
                    SettingsView()
                }
                .alert("Kepto", isPresented: .constant(viewModel.errorMessage != nil)) {
                    Button("OK") { viewModel.errorMessage = nil }
                } message: {
                    Text(viewModel.errorMessage ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.isConfigured {
            ContentUnavailableView {
                Label("Set up Kepto", systemImage: "link.badge.plus")
            } description: {
                Text("Enter your Worker URL and API key in Settings to start saving.")
            } actions: {
                Button("Open Settings") { showingSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if viewModel.isSearching {
            searchResults
        } else if viewModel.collections.isEmpty && !viewModel.isLoading {
            ContentUnavailableView {
                Label("Nothing saved yet", systemImage: "tray")
            } description: {
                Text("Tap + and paste a link from TikTok, Instagram, Threads, X, Facebook, Douyin, or YouTube.")
            } actions: {
                Button("Save a link") { showingSave = true }
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
            .overlay {
                if viewModel.isLoading && viewModel.collections.isEmpty {
                    ProgressView("Loading…")
                }
            }
        }
    }

    private var searchResults: some View {
        ScrollView {
            LazyVGrid(columns: videoColumns, spacing: 2) {
                ForEach(viewModel.items) { item in
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        VideoGridCell(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            if viewModel.hasMore {
                HStack {
                    Spacer()
                    if viewModel.isLoadingMore {
                        ProgressView()
                    } else {
                        Button("Load more") {
                            Task { await viewModel.loadMore() }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView("Loading…")
            } else if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing saved matches this search yet.")
                }
            }
        }
    }
}

/// One collection card (home grid): cover thumbnail, @username, video count.
private struct CollectionCard: View {
    let collection: CollectionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            }
            .aspectRatio(4 / 5, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(collection.count) video\(collection.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }
}

/// One video cell in the 3-column grid (TikTok profile style): portrait
/// thumbnail with a duration badge, a spinner while pending, and a red
/// dot when ingest failed.
struct VideoGridCell: View {
    let item: Item

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AuthenticatedThumbnail(item: item)
                .aspectRatio(3 / 4, contentMode: .fill)
                .clipped()
            if item.status == .pending {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView()
                        .tint(.white)
                }
            }
            if let duration = item.formattedDuration, item.status == .ready {
                Text(duration)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .padding(6)
            }
            if item.status == .failed {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .padding(6)
            }
        }
        .background(Color(.systemGray5))
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
