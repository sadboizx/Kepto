import PhotosUI
import SwiftUI

/// Kepto — cloud-only social archive (MVP v1 + v2).
///
/// The iOS app is a thin client over the Kepto Workers backend:
/// send a link, the ingest service downloads the real media + metadata
/// to R2, and the app plays it back from R2. The original post can be
/// deleted afterwards — the copy in R2 is unaffected.
///
/// No App Store distribution: this build is unsigned and signed on-device
/// with Feather. No local media storage, no download-to-Photos, no
/// CoreData media store.
///
/// The Share Extension ("Save to Kepto" in the iOS share sheet) hands a
/// link to this app via the `kepto://save?url=...` URL scheme (see
/// Kepto/Info.plist); the app opens the Save sheet for it and saves
/// automatically. The extension itself cannot save directly — it has no
/// access to the app's Keychain/API key (no App Groups on a
/// Feather-signed build), so the handoff goes through the app.
@main
struct KeptoApp: App {
    @StateObject private var viewModel = LibraryViewModel()

    init() {
        // The tab bar (Library / For You / Albums / Search) MUST have
        // a solid, opaque background. SwiftUI's
        // `.toolbarBackground(_:for: .tabBar)` did NOT take effect —
        // the bar stayed fully transparent over the grid (IMG_0940,
        // still transparent after both ultraThinMaterial in v37 and
        // regularMaterial in v38), so configure the UITabBar itself
        // at the UIKit level instead. An opaque appearance cannot be
        // transparent. Both appearances are set: standardAppearance
        // (scrolled) AND scrollEdgeAppearance (at the scroll edge) —
        // if scrollEdgeAppearance is left unset, iOS falls back to a
        // transparent bar at the top of the grid.
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor.systemGray6
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }

    var body: some Scene {
        WindowGroup {
            KeptoTabView()
                .environmentObject(viewModel)
                .onOpenURL { url in
                    guard url.scheme == "kepto",
                          url.host == "save",
                          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
                          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    viewModel.pendingShareURL = raw
                }
        }
    }
}

/// The app's root: a Photos-style bottom tab bar with four tabs
/// (Library / For You / Albums / Search). It follows the system
/// appearance like the Photos app (Q11) — no forced dark mode.
///
/// The Share Extension handoff (`kepto://save?url=...`) is handled
/// HERE, not in the Library tab: the Library is only one tab now,
/// and a tab that is not selected is not in the view hierarchy, so
/// its `.onChange` would miss a link handed over while another tab
/// is showing. The root is always mounted, so it always catches it.
/// After saving, the app switches to the Library tab so the new item
/// is visible at the top of the grid.
struct KeptoTabView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var selectedTab = 0
    /// One-line notice after a Share Extension save (e.g. "already
    /// saved" or a collection summary).
    @State private var shareSaveNotice: String?

    var body: some View {
        // Tab icons are exactly the iOS Photos ones (Q12): one icon
        // per tab, no filled variant (photo.on.rectangle.angled,
        // heart.rectangle, rectangle.stack, magnifyingglass).
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem { Label(L10n.library, systemImage: "photo.on.rectangle.angled") }
                .tag(0)
            ForYouView()
                .tabItem { Label(L10n.forYou, systemImage: "heart.rectangle") }
                .tag(1)
            AlbumsView()
                .tabItem { Label(L10n.albums, systemImage: "rectangle.stack") }
                .tag(2)
            SearchView()
                .tabItem { Label(L10n.search, systemImage: "magnifyingglass") }
                .tag(3)
        }
        // NOTE: no SwiftUI .toolbarBackground here — it did not take
        // effect (bar stayed transparent, IMG_0940). The tab bar
        // background is set at the UIKit level in KeptoApp.init()
        // (UITabBarAppearance, opaque), which cannot be transparent.
        .onChange(of: viewModel.pendingShareURL) { _, newValue in
            if let newValue {
                viewModel.pendingShareURL = nil
                Task { await saveSharedLink(newValue) }
            }
        }
        .alert("Kepto", isPresented: .constant(shareSaveNotice != nil)) {
            Button("OK") { shareSaveNotice = nil }
        } message: {
            Text(shareSaveNotice ?? "")
        }
        // Photo Library: the picker is attached HERE (the root),
        // not in a tab, so any tab's "…" menu can open it by setting
        // viewModel.showingPhotoPicker = true. The ViewModel owns the
        // picker state and the whole upload flow.
        .photosPicker(isPresented: $viewModel.showingPhotoPicker, selection: $viewModel.selectedPhotos, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: viewModel.selectedPhotos) { _, newValue in
            guard !newValue.isEmpty else { return }
            let items = newValue
            viewModel.selectedPhotos = []
            Task { await viewModel.uploadPickedPhotos(items) }
        }
        // If the picker was dismissed without picking (Add Photos
        // cancelled), clear the pre-chosen album so a later import
        // doesn't silently land in the wrong album. Guarded on
        // selectedPhotos being empty + no upload running, so a real
        // pick (which sets selectedPhotos and starts uploading) is
        // never cleared.
        .onChange(of: viewModel.showingPhotoPicker) { _, isPresented in
            if !isPresented && !viewModel.isUploading && viewModel.selectedPhotos.isEmpty {
                viewModel.chosenImportAlbum = nil
            }
        }
        // Choose Files: the Files-app document picker is attached
        // HERE (the root), like the PhotosPicker, so any tab's "…"
        // menu can open it by setting
        // viewModel.showingDocumentPicker = true. The ViewModel owns
        // the picker state and the whole upload flow.
        .sheet(isPresented: $viewModel.showingDocumentPicker) {
            DocumentPickerView { urls in
                viewModel.showingDocumentPicker = false
                Task { await viewModel.uploadPickedFiles(urls) }
            } onCancel: {
                viewModel.showingDocumentPicker = false
                // Cancelled without picking: clear a pre-chosen album
                // (same rule as the PhotosPicker above) so a later
                // import doesn't silently land in the wrong album.
                if !viewModel.isUploading {
                    viewModel.chosenImportAlbum = nil
                }
            }
        }
        // Spinner pill while a Photos import is in flight, floating
        // above the tab bar (and above the Library's view-mode pill).
        .overlay(alignment: .bottom) {
            if viewModel.isUploading {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(viewModel.uploadTotal > 1 ? "Đang tải lên \(viewModel.uploadDone)/\(viewModel.uploadTotal)…" : "Đang tải lên…")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 100)
            }
        }
        // One-line notice after a Photos import.
        .alert("Kepto", isPresented: .constant(viewModel.uploadNotice != nil)) {
            Button("OK") { viewModel.uploadNotice = nil }
        } message: {
            Text(viewModel.uploadNotice ?? "")
        }
        // Album picker after a Photos import: the user chooses which
        // album the just-uploaded items go into (or creates a new
        // one). Cancel leaves them in the Library, in no album.
        .sheet(isPresented: $viewModel.showingImportAlbumPicker) {
            ImportAlbumPickerView()
                .environmentObject(viewModel)
        }
    }

    /// Saves a link handed over by the Share Extension, then shows
    /// the Library tab so the new item is visible. Same notices as
    /// the Library's own direct save (duplicate / collection summary).
    private func saveSharedLink(_ rawURL: String) async {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let result = await viewModel.save(url: trimmed) else { return }
        selectedTab = 0
        switch result {
        case .single(let single):
            if single.duplicate {
                shareSaveNotice = "Link này đã lưu trước đó."
            }
        case .collection(let coll):
            var notice = "Đã lưu \(coll.created) video mới"
            if coll.duplicates > 0 {
                notice += " (\(coll.duplicates) video đã có trước đó)"
            }
            if coll.capped {
                notice += " — chỉ lấy 100 video đầu"
            }
            if let title = coll.title, !title.isEmpty {
                notice = "Collection “\(title)”: " + notice
            }
            shareSaveNotice = notice + "."
        }
    }
}
