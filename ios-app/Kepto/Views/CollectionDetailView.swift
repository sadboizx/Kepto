import SwiftUI

/// One collection's videos: a 3-column portrait grid like a TikTok profile
/// page, newest first, with a status filter on top. Tapping a video opens
/// it in the full-screen feed (swipe up/down for the next video in this
/// collection). Pull-to-refresh reloads the collection.
struct CollectionDetailView: View {
    let collection: CollectionInfo
    @EnvironmentObject private var viewModel: LibraryViewModel

    @State private var items: [Item] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var selectedStatus: ItemStatus?
    @State private var errorMessage: String?
    /// The video the feed opens on (nil = feed closed).
    @State private var feedStartItem: Item?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Picker("Status", selection: $selectedStatus) {
                    Text("All").tag(nil as ItemStatus?)
                    ForEach(ItemStatus.allCases) { status in
                        Text(status.displayName).tag(status as ItemStatus?)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            feedStartItem = item
                        } label: {
                            VideoGridCell(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if nextCursor != nil {
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView()
                        } else {
                            Button("Load more") {
                                Task { await loadMore() }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle(collection.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await fetch(reset: true)
        }
        .task {
            await fetch(reset: true)
        }
        .onChange(of: selectedStatus) { _, _ in
            Task { await fetch(reset: true) }
        }
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView("Loading…")
            } else if items.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("No videos yet", systemImage: "tray")
                } description: {
                    Text("Videos saved from \(collection.displayName) will appear here.")
                }
            }
        }
        .alert("Kepto", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenCover(item: $feedStartItem) { startItem in
            FeedView(
                items: $items,
                startItemId: startItem.id,
                onNearEnd: { await loadMore() },
                showCloseButton: true
            )
        }
    }

    private func fetch(reset: Bool) async {
        guard !isLoading && !isLoadingMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (page, cursor) = try await viewModel.listCollection(
                authorUsername: collection.id,
                status: selectedStatus,
                limit: 50,
                cursor: reset ? nil : nextCursor
            )
            items = reset ? page : items + page
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadMore() async {
        guard nextCursor != nil, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let (page, cursor) = try await viewModel.listCollection(
                authorUsername: collection.id,
                status: selectedStatus,
                limit: 50,
                cursor: nextCursor
            )
            items.append(contentsOf: page)
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
