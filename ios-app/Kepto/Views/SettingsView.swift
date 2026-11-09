import SwiftUI

/// Settings: Worker base URL + API key, and a Test Connection button.
/// The base URL is not a secret and lives in UserDefaults; the API key
/// lives in the Keychain (see `KeychainService`). Nothing is hardcoded.
struct SettingsView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String = KeptoAPI.storedBaseURL
    @State private var apiKey: String = ""
    @State private var keyLoaded = false
    @State private var saveMessage: String?
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://kepto.<...>.workers.dev", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if keyLoaded && !apiKey.isEmpty {
                        Button("Clear saved API key", role: .destructive) {
                            try? KeychainService.delete()
                            apiKey = ""
                            saveMessage = "API key removed."
                        }
                    }
                    Button("Save") {
                        saveSettings()
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.isEmpty)
                    if let saveMessage {
                        Text(saveMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Worker")
                } footer: {
                    Text("The Worker URL is your own Kepto deployment. The API key is the KEPTO_API_KEY secret set with wrangler secret put — it is stored in the Keychain, never in the app's files.")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Checks GET /api/health (no auth), then GET /api/list with your API key.")
                }

                Section {
                    LabeledContent("Version", value: "1.0 (MVP)")
                    LabeledContent("Storage", value: "Cloud only (R2)")
                } header: {
                    Text("About")
                } footer: {
                    Text("Kepto is cloud-only: saved media lives in your R2 bucket, metadata in D1. Nothing is downloaded to Photos and nothing is stored on this phone. No App Store build — this IPA is signed on-device with Feather.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        viewModel.reloadConfig()
                        dismiss()
                    }
                }
            }
            .task {
                // Load the stored key once so the field is not blank when
                // the user only wants to change the URL.
                if !keyLoaded {
                    apiKey = KeychainService.currentAPIKey ?? ""
                    keyLoaded = true
                }
            }
        }
    }

    private func saveSettings() {
        KeptoAPI.storeBaseURL(baseURL)
        do {
            try KeychainService.save(apiKey)
            saveMessage = "Saved. The library will use the new settings."
            viewModel.reloadConfig()
        } catch {
            saveMessage = "Could not save the API key: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Health first (proves the URL is reachable), then an authenticated
    /// list call (proves the API key works). Both must pass.
    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBase),
              url.scheme == "http" || url.scheme == "https" else {
            testResult = "❌ Worker URL is not a valid http(s) URL."
            return
        }
        // Save the URL first so the test uses what the user just typed.
        KeptoAPI.storeBaseURL(trimmedBase)
        let api = KeptoAPI(baseURL: url, apiKey: apiKey)
        do {
            let healthy = try await api.health()
            guard healthy else {
                testResult = "❌ Worker replied, but /api/health did not return ok."
                return
            }
            let (items, _) = try await api.list(limit: 1)
            testResult = "✅ Connected. Health OK, auth OK — \(items.count) item(s) on the first page."
        } catch {
            testResult = "❌ \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}
