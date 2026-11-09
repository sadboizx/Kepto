import SwiftUI

/// Kepto — cloud-only social archive (MVP v1).
///
/// The iOS app is a thin client over the Kepto Workers backend:
/// send a link, the ingest service downloads the real media + metadata
/// to R2, and the app plays it back from R2. The original post can be
/// deleted afterwards — the copy in R2 is unaffected.
///
/// No App Store distribution: this build is unsigned and signed on-device
/// with Feather. No local media storage, no download-to-Photos, no
/// CoreData media store. The next step after v1 is a Share Extension so
/// links can be saved straight from TikTok / Instagram / X.
@main
struct KeptoApp: App {
    @StateObject private var viewModel = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(viewModel)
        }
    }
}
