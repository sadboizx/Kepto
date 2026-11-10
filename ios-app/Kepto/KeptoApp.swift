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
/// (Library / For You / Albums / Search) and dark mode forced
/// app-wide (`.preferredColorScheme(.dark)` on the root — the whole
/// app is dark, like the Photos app in the user's screenshots).
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
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                .tag(0)
            ForYouView()
                .tabItem { Label("For You", systemImage: "heart.text.square") }
                .tag(1)
            AlbumsView()
                .tabItem { Label("Albums", systemImage: "square.stack") }
                .tag(2)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(3)
        }
        .preferredColorScheme(.dark)
        // The tab bar (Library / For You / Albums / Search) gets an
        // explicit dark background like the real Photos app: without
        // it the bar is so translucent over the grid that it looks
        // like it has no background at all.
        .toolbarBackground(Color.black.opacity(0.75), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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
