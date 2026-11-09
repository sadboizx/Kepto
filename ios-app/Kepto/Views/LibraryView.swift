import SwiftUI

/// Library: the app's home screen. Lists saved items newest-first with
/// pull-to-refresh, server-side search (`q`), platform filter, and status
/// filter. Rows show an authenticated thumbnail — AsyncImage cannot send
/// the Authorization header, so `AuthenticatedThumbnail` loads it with
/// URLSession instead (see `KeptoAPI.fetchThumbnail`).
struct LibraryView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var showingSave = false
    @State private var showingSettings = false
    @State private var searchTask: Task<Void, Never>?

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
                .searchable(text: $viewModel.searchText, prompt: "Search title, caption, author")
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
                .onChange(of: viewModel.selectedPlatform) { _, _ in
                    Task { await viewModel.fetch() }
                }
                .onChange(of: viewModel.selectedStatus) { _, _ in
                    Task { await viewModel.fetch() }
                }
                .refreshable {
                    await viewModel.fetch()
                }
                .task {
                    await viewModel.fetch()
                }
                .sheet(isPresented: $showingSave) {
                    SaveView()
                }
                .sheet(isPresented: $showingSettings, onDismiss: {
                    viewModel.reloadConfig()
                    Task { await viewModel.fetch() }
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
        } else if viewModel.items.isEmpty && !viewModel.isLoading {
            ContentUnavailableView {
                Label("Nothing saved yet", systemImage: "tray")
            } description: {
                Text("Tap + and paste a link from TikTok, Instagram, Threads, X, Facebook, Douyin, or YouTube.")
            } actions: {
                Button("Save a link") { showingSave = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                filtersSection
                ForEach(viewModel.items) { item in
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        ItemRow(item: item)
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
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .overlay {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView("Loading…")
                }
            }
        }
    }

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Platform", selection: $viewModel.selectedPlatform) {
                Text("All").tag(nil as Platform?)
                ForEach(Platform.allCases) { platform in
                    Text(platform.displayName).tag(platform as Platform?)
                }
            }
            .pickerStyle(.menu)
            Picker("Status", selection: $viewModel.selectedStatus) {
                Text("All").tag(nil as ItemStatus?)
                ForEach(ItemStatus.allCases) { status in
                    Text(status.displayName).tag(status as ItemStatus?)
                }
            }
            .pickerStyle(.segmented)
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
    }
}

/// One library row: thumbnail, title, author + platform, duration, status.
private struct ItemRow: View {
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedThumbnail(item: item)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.displayAuthor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.platform.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let duration = item.formattedDuration {
                        Text("· \(duration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                StatusBadge(status: item.status)
            }
        }
        .padding(.vertical, 2)
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
private struct AuthenticatedThumbnail: View {
    let item: Item
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var image: UIImage?

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
        .task(id: item.id) {
            guard image == nil, let api = viewModel.api else { return }
            image = try? await api.fetchThumbnail(for: item)
        }
    }
}
