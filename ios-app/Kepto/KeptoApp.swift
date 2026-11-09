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
            LibraryView()
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
