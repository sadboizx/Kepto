import SwiftUI

/// Save: paste a social link, POST /api/save, and show the result.
/// Ingest runs in the background — a saved item is `pending` until
/// the ingest service finishes, then it appears as `ready` in the library.
/// A link that was already saved shows "Already saved" instead of a
/// second copy (the backend dedupes by URL).
///
/// The Share Extension opens this sheet with `initialURL` + `autoSave`,
/// so a link shared from TikTok / Instagram / X saves without extra taps.
struct SaveView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    let initialURL: String
    let autoSave: Bool

    @State private var urlText: String
    @State private var isSaving = false
    @State private var savedResult: SaveResult?
    @State private var errorMessage: String?

    init(initialURL: String = "", autoSave: Bool = false) {
        self.initialURL = initialURL
        self.autoSave = autoSave
        self._urlText = State(initialValue: initialURL)
    }

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

                if let savedResult {
                    Section {
                        HStack(spacing: 12) {
                            StatusBadge(status: savedResult.item.status)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(savedResult.item.displayTitle)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(2)
                                Text(savedResult.item.platform.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if savedResult.duplicate {
                            Text("Link này đã lưu rồi — không tạo bản sao mới. Mở collection \(savedResult.item.collectionName) để xem lại.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if savedResult.retried {
                            Text("Link này đã lưu trước đó nhưng ingest bị lỗi — đã lưu lại, ingest đang chạy. Kéo xuống để refresh thư viện.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Saved as pending — ingest is running in the background. Pull to refresh the library to see it become ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Done") { dismiss() }
                    } header: {
                        Text(savedResult.duplicate ? "Already saved" : "Saved")
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
            .onAppear {
                if autoSave && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await save() }
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        savedResult = nil
        errorMessage = nil
        defer { isSaving = false }
        // The view model maps failures to plain messages:
        // 401 -> check the API key, offline -> check the connection.
        if let result = await viewModel.save(url: urlText) {
            savedResult = result
        } else {
            errorMessage = viewModel.errorMessage ?? "Could not save this link."
        }
    }
}
