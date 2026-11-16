import UIKit

/// Item-based thumbnail pipeline replacing Photos' PHCachingImageManager.
///
/// Thumbnails come from the Worker (GET /api/thumb/:id, Bearer auth)
/// via `KeptoAPI.fetchThumbnail(id:)`, which already serves from its
/// in-memory NSCache. This pipeline adds what the grid needs on top:
/// in-flight dedup (one network fetch per id even when many cells ask
/// at once) and prefetch for the rows around the visible area.
/// Nothing is written to disk — memory only, like the rest of Kepto.
///
/// Photos' `ImagePipeline` is deliberately NOT ported: it is PhotoKit
/// throughout (`PHCachingImageManager`, `PHAsset`, `PHImageRequestID`)
/// and has no Kepto equivalent. The prefetch here mirrors Photos'
/// `startCaching` — and like Photos, there is no stop call: these are
/// small thumbnail fetches and the results land in the shared cache.
@MainActor
final class ThumbnailPipeline {
    static let shared = ThumbnailPipeline()

    /// In-flight fetches, keyed by item id. A second caller for the
    /// same id awaits the same Task instead of starting a new fetch.
    private var inFlight: [String: FetchBox] = [:]

    private init() {}

    /// The thumbnail for one item id, via the shared KeptoAPI cache
    /// when possible. Returns nil when the Worker has no thumbnail
    /// for the id or the fetch fails — callers show a placeholder.
    func thumbnail(id: String, api: KeptoAPI) async -> UIImage? {
        if let existing = inFlight[id] {
            return try? await existing.task.value
        }
        let box = FetchBox(Task { try await api.fetchThumbnail(id: id) })
        inFlight[id] = box
        defer { if inFlight[id] === box { inFlight[id] = nil } }
        return try? await box.task.value
    }

    /// Start fetching thumbnails for ids the grid is about to show
    /// (the visible rows plus a screen or two below). Fire-and-forget:
    /// results land in `KeptoAPI`'s cache, so the cells that appear
    /// next read them without a network round trip. Pass a bounded
    /// list — the default cap is 60 ids.
    func prefetch(ids: [String], api: KeptoAPI, limit: Int = 60) {
        var started = 0
        for id in ids {
            guard started < limit else { break }
            guard inFlight[id] == nil else { continue }
            let box = FetchBox(Task { try await api.fetchThumbnail(id: id) })
            inFlight[id] = box
            started += 1
            Task {
                _ = try? await box.task.value
                if self.inFlight[id] === box { self.inFlight[id] = nil }
            }
        }
    }
}

/// Reference box so an in-flight fetch can be found and removed by
/// identity. `Task` itself is a struct, so it cannot be compared
/// with `===`.
private final class FetchBox {
    let task: Task<UIImage?, Error>
    init(_ task: Task<UIImage?, Error>) { self.task = task }
}
