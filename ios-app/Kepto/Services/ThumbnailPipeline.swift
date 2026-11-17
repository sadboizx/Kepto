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
/// `startCaching` — and unlike Photos, a newer prefetch run supersedes
/// an older one (round-32 generation counter), so fast scrolling does
/// not keep fetching rows the user has already passed.
@MainActor
final class ThumbnailPipeline {
    static let shared = ThumbnailPipeline()

    /// In-flight fetches, keyed by item id. A second caller for the
    /// same id awaits the same Task instead of starting a new fetch.
    private var inFlight: [String: FetchBox] = [:]

    /// Generation counter for prefetch runs (round-32, fast-scroll
    /// degrade): every prefetch() call bumps it, and a running
    /// prefetch stops at the next chunk boundary when a newer run
    /// has started — so a stale prefetch for rows the user has
    /// already scrolled past does not keep starting network fetches
    /// for off-screen cells. Per-cell fetches are NOT cancelled:
    /// in-flight dedup means one fetch per id at most, and its
    /// result lands in the shared cache, so scroll-back reuses it.
    private var prefetchGeneration = 0

    private init() {}

    /// Cancel any prefetch run in progress (its in-flight chunk
    /// finishes, later chunks are skipped). Per-cell thumbnail()
    /// fetches are unaffected.
    func cancelPrefetch() {
        prefetchGeneration += 1
    }

    /// The thumbnail for one item id, via the shared KeptoAPI cache
    /// when possible. Returns nil when the Worker has no thumbnail
    /// for the id or the fetch fails — callers show a placeholder.
    func thumbnail(id: String, api: KeptoAPI) async -> UIImage? {
        if let existing = inFlight[id] {
            return try? await existing.task.value
        }
        // Round-28: detached — the fetch, the JPEG decode and the
        // disk write must NOT run on the main actor. This class is
        // @MainActor, so a plain Task inherits it; 40 cells landing
        // at once decoded on main and stalled the album open.
        let box = FetchBox(Task.detached { try await api.fetchThumbnail(id: id) })
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
    /// the same ids is a cheap no-op. At most 8 fetches run at once
    /// (the old version fired up to `limit` at once); the default
    /// cap is 120 ids per call.
    func prefetch(ids: [String], api: KeptoAPI, limit: Int = 120) {
        let missing = ids.filter { !KeptoAPI.hasCachedThumbnail(id: $0) && inFlight[$0] == nil }
            .prefix(limit)
        guard !missing.isEmpty else { return }
        // Round-32: this run supersedes any older prefetch still
        // in flight (fast scroll / album switch) — the older run
        // stops at its next chunk boundary instead of fetching
        // rows that are no longer ahead of the user.
        prefetchGeneration += 1
        let generation = prefetchGeneration
        Task {
            // Bounded concurrency, in caller order: each chunk of 8
            // runs together, the next chunk starts when it finishes. (Round-28
            // revision: 4 -> 8 — the album case warms twice as fast; the
            // thumbnails are tiny and the Worker handles it.)
            // Each fetch goes through thumbnail(id:api:) so in-flight
            // dedup still applies if another caller asks mid-flight.
            var start = missing.startIndex
            while start < missing.endIndex {
                guard generation == self.prefetchGeneration else { return }
                let end = missing.index(start, offsetBy: 8, limitedBy: missing.endIndex) ?? missing.endIndex
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
