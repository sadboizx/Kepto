import UIKit

/// Item-based thumbnail pipeline replacing Photos' PHCachingImageManager.
///
/// Thumbnails come from the Worker (GET /api/thumb/:id, Bearer auth)
/// via `KeptoAPI.fetchThumbnail(id:)`, which serves from its
/// in-memory NSCache + the disk cache under Caches/thumbnails
/// (round-23, persisted across launches). This pipeline adds what
/// the grid needs on top: in-flight dedup (one network fetch per id
/// even when many cells ask at once) and prefetch for the rows
/// around the visible area.
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
    /// next read them without a network round trip. Delta-only
    /// (round-26): ids already cached (memory or disk) and ids
    /// already in flight are skipped, in caller order — the caller
    /// passes newest-first, so the first missing thumbnails
    /// fetched are the ones the user sees first. A second call for
    /// the same ids is a cheap no-op. At most 4 fetches run at once
    /// (the old version fired up to `limit` at once); the default
    /// cap is 120 ids per call.
    func prefetch(ids: [String], api: KeptoAPI, limit: Int = 120) {
        let missing = ids.filter { !KeptoAPI.hasCachedThumbnail(id: $0) && inFlight[$0] == nil }
            .prefix(limit)
        guard !missing.isEmpty else { return }
        Task {
            // Bounded concurrency, in caller order: each chunk of 4
            // runs together, the next chunk starts when it finishes.
            // Each fetch goes through thumbnail(id:api:) so in-flight
            // dedup still applies if another caller asks mid-flight.
            var start = missing.startIndex
            while start < missing.endIndex {
                let end = missing.index(start, offsetBy: 4, limitedBy: missing.endIndex) ?? missing.endIndex
                let chunk = missing[start..<end]
                await withTaskGroup(of: Void.self) { group in
                    for id in chunk {
                        group.addTask { _ = await self.thumbnail(id: id, api: api) }
                    }
                }
                start = end
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
