import SwiftUI

/// Save: paste a social link, POST /api/save, and show the new pending
/// item. Ingest runs in the background — a saved item is `pending` until
/// the ingest service finishes, then it appears as `ready` in the library.
struct SaveView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var isSaving = false
    @State private var savedItem: Item?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://www.tiktok.com/@.../video/...", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSaving || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Link")
                } footer: {
                    Text("TikTok, Instagram, Threads, X, Facebook, Douyin, YouTube — any http(s) link. The original post can be deleted afterwards; the saved copy stays in your cloud.")
                }

                if let savedItem {
                    Section {
                        HStack(spacing: 12) {
                            StatusBadge(status: savedItem.status)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(savedItem.displayTitle)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(2)
                                Text(savedItem.platform.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Saved as pending — ingest is running in the background. Pull to refresh the library to see it become ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Done") { dismiss() }
                    } header: {
                        Text("Saved")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } header: {
                        Text("Could not save")
                    }
                }
            }
            .navigationTitle("Save a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        savedItem = nil
        errorMessage = nil
        defer { isSaving = false }
        // The view model maps failures to plain messages:
        // 401 -> check the API key, offline -> check the connection.
        if let item = await viewModel.save(url: urlText) {
            savedItem = item
        } else {
            errorMessage = viewModel.errorMessage ?? "Could not save this link."
        }
    }
}
