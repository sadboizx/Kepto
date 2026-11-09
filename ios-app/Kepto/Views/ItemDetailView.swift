import SwiftUI

/// Detail for one saved item. Ready items play by streaming from R2 via
/// GET /api/play/:id; pending items show a spinner, failed items show the
/// ingest error. Delete removes the R2 objects and the D1 row server-side.
struct ItemDetailView: View {
    let item: Item
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingDeleteConfirmation = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                playerSection
                titleSection
                metadataSection
                actionsSection
            }
            .padding()
        }
        .navigationTitle(item.platform.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Delete this saved item?",
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteItem() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved copy from the cloud. The original post is not affected.")
        }
        .alert("Delete failed", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .task {
            // A pending item may have become ready while we were away.
            await viewModel.refreshItem(item)
        }
    }

    // MARK: - Player

    @ViewBuilder
    private var playerSection: some View {
        switch item.status {
        case .ready:
            // Custom player: tap to play/pause, and a scrub preview while
            // dragging the progress bar (sprite frame at that timestamp).
            ScrubPreviewPlayer(item: item)
        case .pending:
            VStack(spacing: 8) {
                ProgressView()
                Text("Ingest is still running — the video will appear here when it is ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label("Ingest failed", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(item.ingestError ?? "Unknown error.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Metadata

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayTitle)
                .font(.title3)
                .fontWeight(.semibold)
            HStack(spacing: 6) {
                Text(item.displayAuthor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                StatusBadge(status: item.status)
            }
            if let caption = item.caption, !caption.isEmpty, caption != item.title {
                Text(caption)
                    .font(.body)
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataRow(label: "Platform", value: item.platform.displayName)
            if let posted = item.formattedPostedAt {
                metadataRow(label: "Posted", value: posted)
            }
            if let saved = item.formattedSavedAt {
                metadataRow(label: "Saved", value: saved)
            }
            if let duration = item.formattedDuration {
                metadataRow(label: "Duration", value: duration)
            }
            if let dimensions = item.formattedDimensions {
                metadataRow(label: "Size", value: dimensions)
            }
            if let fileSize = item.formattedFileSize {
                metadataRow(label: "File", value: fileSize)
            }
            if let contentType = item.contentType {
                metadataRow(label: "Type", value: contentType)
            }
        }
        .font(.subheadline)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .lineLimit(3)
            Spacer()
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            // Opens the original post in Safari. Read-only: it does not
            // download or re-save anything. The backend only stores
            // http(s) URLs, so this always parses; the row is hidden
            // entirely if it somehow does not.
            if let originalURL = URL(string: item.originalUrl),
               originalURL.scheme == "http" || originalURL.scheme == "https" {
                Link(destination: originalURL) {
                    Label("Open original in Safari", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete saved copy", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Delete

    private func deleteItem() async {
        do {
            try await viewModel.delete(item: item)
            dismiss()
        } catch {
            deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
