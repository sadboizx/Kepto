/**
 * Kepto — Cloudflare Workers backend (Hono).
 *
 * Cloud-only social archive: the iOS app is a thin client. It sends a link,
 * the ingest service downloads the real media + metadata and uploads it to
 * R2, and the app plays it back from R2. The original post can be deleted
 * afterwards — the copy in R2 is unaffected.
 *
 * Endpoints (all /api/* except /api/health need `Authorization: Bearer <KEPTO_API_KEY>`):
 * - POST /api/save            { url } -> 202 { item } (status pending)
 *                             or 200 { item, duplicate: true } if the link
 *                             was already saved (no second copy is made);
 *                             a previously failed save is retried instead.
 *                             Auto-detects a TikTok Collection link (full
 *                             or short — short links are resolved first)
 *                             and saves the whole collection instead,
 *                             returning the save-collection response.
 * - POST /api/save-collection { url } -> 202 { title, total, created,
 *                             duplicates, capped, collection_id, items }:
 *                             expands a TikTok Collection (or any playlist
 *                             URL) via the ingest service (yt-dlp
 *                             --flat-playlist) and saves every video in it;
 *                             groups them into a user-created collection
 *                             named after the TikTok collection when it
 *                             has a title (best-effort).
 * - GET  /api/list            ?platform=&q=&status=&author_username=&limit=&cursor=
 * - GET  /api/stats           counts for the Library header + Albums tab
 *                             { total, photos, videos, favorites }
 * - GET  /api/collections     one row per author username (the Library's
 *                             home screen), with count + cover item id
 * - GET  /api/my-collections  user-created collections ("Add to collection")
 * - POST /api/my-collections  { name } -> 201 { collection }
 * - GET  /api/my-collections/:id/items   videos in a collection
 * - POST /api/my-collections/:id/items   { item_id } (idempotent)
 * - DELETE /api/my-collections/:id/items/:itemId
 * - DELETE /api/my-collections/:id
 * - GET  /api/items/:id       metadata for one item
 * - POST /api/items/:id/favorite { favorite } -> 200 { item } (heart)
 * - GET  /api/play/:id        streams the media from R2, Range/seek supported
 * - GET  /api/thumb/:id       streams the thumbnail from R2
 * - GET  /api/preview/:id     streams the scrub-preview sprite from R2
 * - DELETE /api/items/:id     deletes R2 objects + D1 row
 * - POST /api/upload          the app uploads a photo/video from the
 *   device Albums (raw file body, ?filename=); the Worker creates a
 *   pending "album" item and streams the body to the ingest /upload
 *   endpoint, which finishes it like a link ingest. The "app never
 *   uploads" rule below applies to LINK saves only — a local file is
 *   already on the device, so uploading it once is the only way in.
 * - POST /api/ingest-complete Bearer <INGEST_TOKEN>, called by the ingest service
 * - GET  /api/health          liveness probe, no auth
 *
 * Ingest contract (ingest service, NOT in this repo — Railway/Fly worker
 * running Cobalt / yt-dlp + ffmpeg):
 *   Worker -> ingest:  POST {INGEST_URL} { item_id, url }
 *                       Authorization: Bearer <INGEST_TOKEN>
 *   Ingest -> Worker:  POST /api/ingest-complete, same Bearer token, body:
 *     success: { item_id, r2_key, thumb_key?, preview_key?, content_type?,
 *                title?, caption?, author?, author_username?,
 *                author_avatar_url?, posted_at?, duration?, width?, height?,
 *                file_size?, sha256?, preview_cols?, preview_rows?,
 *                preview_interval?, preview_count? }
 *     failure: { item_id, error }
 *   Ingest uploads straight to R2 at
 *     users/<userId>/items/<itemId>/original.mp4 (and thumb.jpg / sprite.jpg).
 *   The Worker never downloads video itself — Workers is the wrong place for
 *   large downloads. The iOS app never uploads either (double bandwidth).
 *
 * Auth is single-user for the MVP: one shared KEPTO_API_KEY, user_id 'me'.
 * Multi-user auth (per-user keys / Cloudflare Access) comes later if needed.
 */
import { Hono } from "hono";
import type { Context } from "hono";
import { cors } from "hono/cors";
import type { Env } from "./env";
import {
  addItemToMyCollection,
  createMyCollection,
  deleteItem,
  deleteMyCollection,
  detectPlatform,
  extractVideoId,
  findByUrl,
  findByVideoId,
  findItemBySha256,
  findMyCollectionByName,
  getItem,
  getMyCollection,
  getStats,
  insertItem,
  listCollections,
  listItems,
  listMyCollectionExclusiveItems,
  listMyCollectionItems,
  listMyCollections,
  markFailed,
  markReady,
  normalizeSaveUrl,
  removeItemFromMyCollection,
  renameMyCollection,
  resetForRetry,
  setFavorite,
  type IngestResult,
  type Item,
} from "./db";

const app = new Hono<{ Bindings: Env }>();

app.use("/api/*", cors({ origin: "*", allowMethods: ["GET", "POST", "DELETE", "OPTIONS"] }));

const MAX_BODY_BYTES = 16 * 1024;

function bearer(c: { req: { header: (n: string) => string | undefined } }): string | null {
  const h = c.req.header("Authorization") ?? "";
  return h.startsWith("Bearer ") ? h.slice(7) : null;
}

app.use("/api/*", async (c, next) => {
  // /api/health is public; /api/ingest-complete does its own INGEST_TOKEN
  // check in its handler — it must NOT go through the KEPTO_API_KEY check
  // below (the ingest service authenticates with INGEST_TOKEN, not the key).
  if (c.req.path === "/api/health" || c.req.path === "/api/ingest-complete") return next();
  const token = bearer(c);
  if (!c.env.KEPTO_API_KEY || token !== c.env.KEPTO_API_KEY) {
    return c.json({ ok: false, error: "Unauthorized." }, 401);
  }
  return next();
});

app.get("/api/health", (c) => c.json({ ok: true, service: "kepto" }));

async function readJson(c: Context<{ Bindings: Env }>): Promise<unknown> {
  const raw = await c.req.text();
  if (raw.length > MAX_BODY_BYTES) throw new Error("Payload quá lớn.");
  return raw ? JSON.parse(raw) : {};
}

/**
 * Asks the ingest service to fetch a saved item. Fire-and-forget: a slow
 * ingest must not block the save response, and a failed dispatch marks the
 * item failed so the app shows the real error instead of stuck Pending.
 */
function fireIngest(c: Context<{ Bindings: Env }>, id: string, url: string): void {
  if (!c.env.INGEST_URL) return;
  c.executionCtx.waitUntil(
    (async () => {
      try {
        const res = await fetch(c.env.INGEST_URL, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${c.env.INGEST_TOKEN}`,
          },
          body: JSON.stringify({ item_id: id, url }),
        });
        if (!res.ok) {
          await markFailed(c.env.DB, id, `ingest_http_${res.status}`);
        }
      } catch (e) {
        await markFailed(c.env.DB, id, `ingest_unreachable: ${String(e).slice(0, 200)}`);
      }
    })(),
  );
}

interface SaveOneResult {
  item: Item;
  duplicate: boolean;
  retried: boolean;
}

/**
 * Save one URL: dedupe (an already-saved link returns the existing item;
 * a previously failed save is retried) + insert + fire ingest.
 * Shared by /api/save and /api/save-collection.
 */
async function saveOne(
  c: Context<{ Bindings: Env }>,
  rawUrl: string,
): Promise<SaveOneResult> {
  const url = normalizeSaveUrl(rawUrl);
  let existing = await findByUrl(c.env.DB, url);
  if (!existing) {
    // Fallback: the same video saved under a different URL form —
    // a tracking query string, another host, or a repost under a
    // different username — has a different stored URL, so the exact
    // lookup above misses it and the video would be downloaded again
    // (notably when a Collection re-lists videos saved individually
    // first). Match by the platform video ID instead: the ID is the
    // same no matter how the link was shared.
    const vid = extractVideoId(url);
    if (vid) {
      existing = await findByVideoId(c.env.DB, vid.id);
    }
  }
  if (existing) {
    if (existing.status === "failed") {
      await resetForRetry(c.env.DB, existing.id);
      fireIngest(c, existing.id, url);
      const item = await getItem(c.env.DB, existing.id);
      if (!item) throw new Error("Không đọc được item vừa lưu lại.");
      return { item, duplicate: false, retried: true };
    }
    return { item: existing, duplicate: true, retried: false };
  }
  const id = crypto.randomUUID();
  const platform = detectPlatform(url);
  await insertItem(c.env.DB, { id, user_id: "me", platform, original_url: url });
  fireIngest(c, id, url);
  const item = await getItem(c.env.DB, id);
  if (!item) throw new Error("Không đọc được item vừa tạo.");
  return { item, duplicate: false, retried: false };
}

/**
 * Resolve a URL to its canonical form by following redirects
 * (headers only, up to 5 hops, 10s each). Short links
 * (vt.tiktok.com/...) do not say whether they point at a single
 * video or a Collection, so /api/save resolves them before deciding
 * which flow to run. Returns the input unchanged when there is no
 * redirect or resolving fails.
 */
async function resolveFinalUrl(pageUrl: string): Promise<string> {
  let current = pageUrl;
  for (let hop = 0; hop < 5; hop++) {
    let res: Response;
    try {
      res = await fetch(current, { redirect: "manual", signal: AbortSignal.timeout(10_000) });
    } catch {
      break;
    }
    const loc = res.headers.get("location");
    if (!loc) break;
    try {
      current = new URL(loc, current).toString();
    } catch {
      break;
    }
  }
  return current;
}

/** True when the URL points at a TikTok Collection (or any /collection/ URL). */
function isCollectionUrl(url: string): boolean {
  try {
    return new URL(url).pathname.toLowerCase().includes("/collection/");
  } catch {
    return url.toLowerCase().includes("/collection/");
  }
}

/**
 * Save a link. Dedupe: an already-saved link returns the existing item with
 * `duplicate: true` instead of a second copy. A previously failed save is
 * retried (back to pending + ingest re-fired) instead of duplicating it.
 * Auto-detects Collections: a link that is (or resolves to) a TikTok
 * Collection is saved as a whole collection instead — the app no longer
 * needs a separate "save collection" button; one save flow handles both.
 */
app.post("/api/save", async (c) => {
  let body: unknown;
  try {
    body = await readJson(c);
  } catch {
    return c.json({ ok: false, error: "JSON không hợp lệ." }, 400);
  }
  const rawUrl = (body as { url?: unknown })?.url;
  if (typeof rawUrl !== "string" || !/^https?:\/\//i.test(rawUrl)) {
    return c.json({ ok: false, error: "url phải là link http(s)." }, 422);
  }
  // Collection? A full collection URL says so directly. A TikTok video
  // URL says it is a single video. Anything else (a short link) is
  // ambiguous — resolve it and check the canonical URL.
  const lower = rawUrl.toLowerCase();
  let checkUrl = rawUrl;
  if (!isCollectionUrl(rawUrl) && !lower.includes("/video/")) {
    checkUrl = await resolveFinalUrl(rawUrl);
  }
  if (isCollectionUrl(checkUrl)) {
    return saveCollectionResponse(c, rawUrl);
  }
  const result = await saveOne(c, rawUrl);
  return c.json(
    {
      ok: true,
      item: result.item,
      duplicate: result.duplicate,
      retried: result.retried,
      ingest_configured: Boolean(c.env.INGEST_URL),
    },
    result.duplicate ? 200 : 202,
  );
});

const MAX_COLLECTION_VIDEOS = 100;

/**
 * POST /api/upload — upload a photo/video straight from the device
 * Albums (PhotosPicker). The app sends the raw file bytes as the body
 * (Content-Type = the file's MIME type, filename in ?filename=). The
 * Worker creates a pending item (platform "album", original_url
 * "album://<uuid>") and streams the body through to the ingest service,
 * which probes it, builds a thumbnail (+ a scrub sprite for videos),
 * uploads it to R2, and calls back /api/ingest-complete. The Worker
 * waits for the ingest to finish and returns the finished item.
 *
 * The app uploads through the Worker (not directly to the ingest)
 * because the ingest needs INGEST_TOKEN, which the app never holds.
 * Files over ~100 MB hit the Workers request limit — the app shows
 * that error instead of a silent failure.
 */
app.post("/api/upload", async (c) => {
  const filename = c.req.query("filename") || "upload";
  const contentType = c.req.header("Content-Type") || "application/octet-stream";
  // Content-hash dedupe: the app sends the SHA-256 of the exact bytes
  // it uploads (query ?sha256=). If an item with that hash already
  // exists, skip the upload entirely and return the existing item as
  // a duplicate — the app counts it as "skipped" and keeps uploading
  // the rest of the batch. No new item is created and the ingest is
  // never called for a duplicate.
  const sha256 = c.req.query("sha256") || "";
  if (sha256) {
    const existing = await findItemBySha256(c.env.DB, "me", sha256);
    if (existing) {
      return c.json({ ok: true, duplicate: true, item: existing }, 200);
    }
  }
  const id = crypto.randomUUID();
  await insertItem(c.env.DB, { id, user_id: "me", platform: "album", original_url: `album://${id}` });
  if (!c.env.INGEST_URL || !c.env.INGEST_TOKEN) {
    await markFailed(c.env.DB, id, "ingest_not_configured");
    return c.json({ ok: false, error: "Ingest chưa được cấu hình." }, 500);
  }
  const uploadUrl = c.env.INGEST_URL.replace(/\/ingest\/?$/, "") + "/upload";
  let ingestRes: Response;
  try {
    ingestRes = await fetch(
      `${uploadUrl}?item_id=${id}&filename=${encodeURIComponent(filename)}`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${c.env.INGEST_TOKEN}`,
          "Content-Type": contentType,
        },
        body: c.req.raw.body,
      },
    );
  } catch (e) {
    await markFailed(c.env.DB, id, String(e).slice(0, 500));
    return c.json({ ok: false, error: "Không gọi được ingest service." }, 502);
  }
  if (!ingestRes.ok) {
    const errText = await ingestRes.text().catch(() => "");
    await markFailed(c.env.DB, id, errText.slice(0, 500) || `upload_failed_${ingestRes.status}`);
    return c.json({ ok: false, error: errText || "Tải lên thất bại." }, 502);
  }
  const item = await getItem(c.env.DB, id);
  return c.json({ ok: true, item }, 201);
});

/**
 * Save every video in a TikTok Collection (or any playlist URL yt-dlp
 * can expand). The ingest service expands the collection into video
 * URLs (yt-dlp --flat-playlist, tiktok:collection extractor); this
 * function then saves each one (dedupe + ingest, same as /api/save).
 * When the collection has a title, the videos are also grouped into a
 * user-created collection of that name (best-effort — skipped when
 * migration 0004 has not been applied yet, or the title is missing).
 * Synchronous: expanding takes ~5-30s; the app waits with a spinner
 * (request timeout 120s). Shared by /api/save (auto-detect) and
 * /api/save-collection (explicit, kept for compatibility).
 */
async function saveCollectionResponse(
  c: Context<{ Bindings: Env }>,
  rawUrl: string,
): Promise<Response> {
  if (!c.env.INGEST_URL) {
    return c.json({ ok: false, error: "Ingest chưa được cấu hình." }, 503);
  }
  // Expand via the ingest service (it runs yt-dlp; the Worker cannot).
  // INGEST_URL is the /ingest endpoint; the expand endpoint sits next to it.
  const expandUrl = c.env.INGEST_URL.replace(/\/ingest\/?$/, "") + "/expand-collection";
  let expanded: { title?: string | null; urls?: unknown };
  try {
    const res = await fetch(expandUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${c.env.INGEST_TOKEN}`,
      },
      body: JSON.stringify({ url: rawUrl }),
      signal: AbortSignal.timeout(120_000),
    });
    if (!res.ok) {
      const errBody = (await res.json().catch(() => ({}))) as { error?: unknown };
      const msg = typeof errBody.error === "string" ? errBody.error : `expand_http_${res.status}`;
      return c.json({ ok: false, error: msg }, 422);
    }
    expanded = (await res.json()) as { title?: string | null; urls?: unknown };
  } catch (e) {
    return c.json(
      { ok: false, error: `Không mở được collection: ${String(e).slice(0, 200)}` },
      422,
    );
  }
  const urls = (Array.isArray(expanded.urls) ? expanded.urls : [])
    .filter((u): u is string => typeof u === "string" && /^https?:\/\//i.test(u))
    .slice(0, MAX_COLLECTION_VIDEOS);
  if (!urls.length) {
    return c.json({ ok: false, error: "Không tìm thấy video nào trong collection này." }, 422);
  }
  const items: Item[] = [];
  let duplicates = 0;
  for (const u of urls) {
    const result = await saveOne(c, u);
    if (result.duplicate) duplicates++;
    items.push(result.item);
  }
  // Group the new videos into a user-created collection named after the
  // TikTok collection. Best-effort: a missing my_collections table
  // (migration 0004 not applied) must not fail the save — the videos
  // are already saved; they just are not grouped. Re-saving a
  // collection whose folder already exists REUSES that folder instead
  // of creating a duplicate with the same name.
  let collectionId: string | null = null;
  const title = typeof expanded.title === "string" ? expanded.title.trim() : "";
  if (title) {
    try {
      const name = title.slice(0, 100);
      const existing = await findMyCollectionByName(c.env.DB, "me", name);
      const id = existing?.id ?? crypto.randomUUID();
      if (!existing) {
        await createMyCollection(c.env.DB, { id, user_id: "me", name });
      }
      for (const item of items) {
        await addItemToMyCollection(c.env.DB, id, item.id);
      }
      collectionId = id;
    } catch {
      // Ignore — see above.
    }
  }
  return c.json(
    {
      ok: true,
      title: title || null,
      total: urls.length,
      created: items.length - duplicates,
      duplicates,
      capped: urls.length >= MAX_COLLECTION_VIDEOS,
      collection_id: collectionId,
      items,
    },
    202,
  );
}

/// Explicit collection endpoint, kept for compatibility. The app now
/// just calls /api/save — it auto-detects a Collection link.
app.post("/api/save-collection", async (c) => {
  let body: unknown;
  try {
    body = await readJson(c);
  } catch {
    return c.json({ ok: false, error: "JSON không hợp lệ." }, 400);
  }
  const rawUrl = (body as { url?: unknown })?.url;
  if (typeof rawUrl !== "string" || !/^https?:\/\//i.test(rawUrl)) {
    return c.json({ ok: false, error: "url phải là link http(s)." }, 422);
  }
  return saveCollectionResponse(c, rawUrl);
});

/** List saved items, newest first. cursor = base64 JSON {saved_at, id} from the last item. */
app.get("/api/list", async (c) => {
  const q = c.req.query("q") ?? undefined;
  const platform = c.req.query("platform") ?? undefined;
  const status = c.req.query("status") ?? undefined;
  const authorUsername = c.req.query("author_username") ?? undefined;
  const media = c.req.query("media") ?? undefined;
  const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50) || 50, 1), 100);
  let cursor: { saved_at: string; id: string } | undefined;
  const rawCursor = c.req.query("cursor");
  if (rawCursor) {
    try {
      cursor = JSON.parse(atob(rawCursor)) as { saved_at: string; id: string };
    } catch {
      return c.json({ ok: false, error: "cursor không hợp lệ." }, 400);
    }
  }
  const items = await listItems(c.env.DB, {
    userId: "me",
    platform,
    status,
    q,
    authorUsername,
    media,
    favorite: c.req.query("favorite") === "1",
    limit,
    cursor,
  });
  const hasMore = items.length > limit;
  const page = hasMore ? items.slice(0, limit) : items;
  const last = page[page.length - 1];
  const nextCursor =
    hasMore && last
      ? btoa(JSON.stringify({ saved_at: last.saved_at, id: last.id }))
      : null;
  return c.json({ ok: true, items: page, next_cursor: nextCursor });
});

/** Library counts for the Photos-style header ("N Photos, M Videos")
 * and the Albums tab (Recents = total, Favorites = favorites). */
app.get("/api/stats", async (c) => {
  const stats = await getStats(c.env.DB, "me");
  return c.json({ ok: true, ...stats });
});

/** Collections: one row per author username, newest first. The Library home screen. */
app.get("/api/collections", async (c) => {
  const collections = await listCollections(c.env.DB, "me");
  return c.json({ ok: true, collections });
});

/**
 * My collections: user-created lists (TikTok-style "Add to collection").
 * These are separate from the per-creator collections above (automatic).
 * Needs migration 0004 (my_collections + my_collection_items).
 */
app.get("/api/my-collections", async (c) => {
  const collections = await listMyCollections(c.env.DB, "me");
  return c.json({ ok: true, collections });
});

app.post("/api/my-collections", async (c) => {
  let body: unknown;
  try {
    body = await readJson(c);
  } catch {
    return c.json({ ok: false, error: "JSON không hợp lệ." }, 400);
  }
  const name = (body as { name?: unknown })?.name;
  if (typeof name !== "string" || name.trim().length === 0) {
    return c.json({ ok: false, error: "Tên collection là bắt buộc." }, 422);
  }
  const id = crypto.randomUUID();
  await createMyCollection(c.env.DB, { id, user_id: "me", name: name.trim().slice(0, 100) });
  const collection = await getMyCollection(c.env.DB, id);
  return c.json({ ok: true, collection }, 201);
});

/** Rename a user collection. PATCH /api/my-collections/:id { name } -> 200 { collection }. */
app.patch("/api/my-collections/:id", async (c) => {
  const collection = await getMyCollection(c.env.DB, c.req.param("id"));
  if (!collection) return c.json({ ok: false, error: "Không tìm thấy collection." }, 404);
  let body: unknown;
  try {
    body = await readJson(c);
  } catch {
    return c.json({ ok: false, error: "JSON không hợp lệ." }, 400);
  }
  const name = (body as { name?: unknown })?.name;
  if (typeof name !== "string" || name.trim().length === 0) {
    return c.json({ ok: false, error: "Tên collection là bắt buộc." }, 422);
  }
  const updated = await renameMyCollection(c.env.DB, collection.id, name.trim().slice(0, 100));
  return c.json({ ok: true, collection: updated });
});

/** Videos in a collection, newest-added first (keyset cursor, like /api/list). */
app.get("/api/my-collections/:id/items", async (c) => {
  const collection = await getMyCollection(c.env.DB, c.req.param("id"));
  if (!collection) return c.json({ ok: false, error: "Không tìm thấy collection." }, 404);
  const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50) || 50, 1), 100);
  let cursor: { added_at: string; item_id: string } | undefined;
  const rawCursor = c.req.query("cursor");
  if (rawCursor) {
    try {
      cursor = JSON.parse(atob(rawCursor)) as { added_at: string; item_id: string };
    } catch {
      return c.json({ ok: false, error: "cursor không hợp lệ." }, 400);
    }
  }
  const rows = await listMyCollectionItems(c.env.DB, {
    collectionId: collection.id,
    limit,
    cursor,
  });
  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  const last = page[page.length - 1];
  const nextCursor =
    hasMore && last
      ? btoa(JSON.stringify({ added_at: last.added_at, item_id: last.id }))
      : null;
  return c.json({ ok: true, items: page, next_cursor: nextCursor });
});

/** Add a video to a collection. Idempotent: adding twice returns duplicate. */
app.post("/api/my-collections/:id/items", async (c) => {
  const collection = await getMyCollection(c.env.DB, c.req.param("id"));
  if (!collection) return c.json({ ok: false, error: "Không tìm thấy collection." }, 404);
  let body: unknown;
  try {
    body = await readJson(c);
  } catch {
    return c.json({ ok: false, error: "JSON không hợp lệ." }, 400);
  }
  const itemId = (body as { item_id?: unknown })?.item_id;
  if (typeof itemId !== "string" || itemId.length === 0) {
    return c.json({ ok: false, error: "item_id là bắt buộc." }, 422);
  }
  const item = await getItem(c.env.DB, itemId);
  if (!item) return c.json({ ok: false, error: "Không tìm thấy item." }, 404);
  const added = await addItemToMyCollection(c.env.DB, collection.id, itemId);
  return c.json({ ok: true, added, duplicate: !added });
});

/** Remove a video from a collection (the item stays saved in the library). */
app.delete("/api/my-collections/:id/items/:itemId", async (c) => {
  const collection = await getMyCollection(c.env.DB, c.req.param("id"));
  if (!collection) return c.json({ ok: false, error: "Không tìm thấy collection." }, 404);
  await removeItemFromMyCollection(c.env.DB, collection.id, c.req.param("itemId"));
  return c.json({ ok: true, removed: true });
});

/**
 * Delete a collection and its memberships. By default the videos stay
 * saved in the library (Photos behavior). With ?delete_items=1, the
 * videos that live ONLY in this album are permanently deleted too
 * (R2 media + D1 rows); a video that is also in another album is
 * kept — it stays saved in that album.
 */
app.delete("/api/my-collections/:id", async (c) => {
  const collection = await getMyCollection(c.env.DB, c.req.param("id"));
  if (!collection) return c.json({ ok: false, error: "Không tìm thấy collection." }, 404);
  let deletedItems = 0;
  if (c.req.query("delete_items") === "1") {
    const rows = await listMyCollectionExclusiveItems(c.env.DB, collection.id);
    const keys: string[] = [];
    for (const row of rows) {
      for (const k of [row.r2_key, row.thumb_key, row.preview_key]) {
        if (k) keys.push(k);
      }
      await deleteItem(c.env.DB, row.id);
    }
    if (keys.length) await c.env.MEDIA.delete(keys);
    deletedItems = rows.length;
  }
  await deleteMyCollection(c.env.DB, collection.id);
  return c.json({ ok: true, deleted: collection.id, deleted_items: deletedItems });
});

app.get("/api/items/:id", async (c) => {
  const item = await getItem(c.env.DB, c.req.param("id"));
  if (!item) return c.json({ ok: false, error: "Không tìm thấy item." }, 404);
  return c.json({ ok: true, item });
});

app.delete("/api/items/:id", async (c) => {
  const item = await getItem(c.env.DB, c.req.param("id"));
  if (!item) return c.json({ ok: false, error: "Không tìm thấy item." }, 404);
  c.executionCtx.waitUntil(
    (async () => {
      const keys = [item.r2_key, item.thumb_key, item.preview_key].filter(
        (k): k is string => Boolean(k),
      );
      if (keys.length) await c.env.MEDIA.delete(keys);
    })(),
  );
  await deleteItem(c.env.DB, item.id);
  return c.json({ ok: true, deleted: item.id });
});

/**
 * Favorite / unfavorite an item (heart). POST /api/items/:id/favorite
 * { favorite: true|false } -> 200 { item }. Needs migration 0005
 * (is_favorite column); without it the UPDATE fails and the app
 * shows the error.
 */
app.post("/api/items/:id/favorite", async (c) => {
  let body: unknown;
  try {
    body = await readJson(c);
  } catch {
    return c.json({ ok: false, error: "JSON không hợp lệ." }, 400);
  }
  const favorite = (body as { favorite?: unknown })?.favorite;
  if (typeof favorite !== "boolean") {
    return c.json({ ok: false, error: "favorite phải là true/false." }, 422);
  }
  const item = await getItem(c.env.DB, c.req.param("id"));
  if (!item) return c.json({ ok: false, error: "Không tìm thấy item." }, 404);
  await setFavorite(c.env.DB, item.id, favorite);
  const updated = await getItem(c.env.DB, item.id);
  return c.json({ ok: true, item: updated });
});

/** Ingest service callback. Success marks the item ready; failure records the error. */
app.post("/api/ingest-complete", async (c) => {
  if (!c.env.INGEST_TOKEN || bearer(c) !== c.env.INGEST_TOKEN) {
    return c.json({ ok: false, error: "Unauthorized." }, 401);
  }
  let body: unknown;
  try {
    body = await readJson(c);
  } catch {
    return c.json({ ok: false, error: "JSON không hợp lệ." }, 400);
  }
  const b = body as Partial<IngestResult> & { error?: unknown };
  if (typeof b.item_id !== "string") {
    return c.json({ ok: false, error: "item_id là bắt buộc." }, 422);
  }
  const item = await getItem(c.env.DB, b.item_id);
  if (!item) return c.json({ ok: false, error: "Không tìm thấy item." }, 404);
  if (typeof b.error === "string") {
    await markFailed(c.env.DB, b.item_id, b.error);
    return c.json({ ok: true, item: await getItem(c.env.DB, b.item_id) });
  }
  if (typeof b.r2_key !== "string") {
    return c.json({ ok: false, error: "r2_key là bắt buộc khi thành công." }, 422);
  }
  await markReady(c.env.DB, b as IngestResult);
  return c.json({ ok: true, item: await getItem(c.env.DB, b.item_id) });
});

/** Parse `Range: bytes=start-end` into a clamped { start, end } (inclusive). Null = no/invalid range. */
function parseRange(
  header: string | null,
  size: number,
): { start: number; end: number } | null {
  if (!header || !header.startsWith("bytes=")) return null;
  const spec = header.slice(6).trim();
  if (spec.startsWith("-")) {
    const suffix = Number(spec.slice(1));
    if (!Number.isFinite(suffix) || suffix <= 0) return null;
    return { start: Math.max(size - Math.min(suffix, size), 0), end: size - 1 };
  }
  const [startStr, endStr] = spec.split("-");
  const start = Number(startStr);
  if (!Number.isFinite(start) || start < 0 || start >= size) return null;
  if (endStr === "" || endStr === undefined) return { start, end: size - 1 };
  const end = Number(endStr);
  if (!Number.isFinite(end) || end < start) return null;
  return { start, end: Math.min(end, size - 1) };
}

async function streamFromR2(
  c: Context<{ Bindings: Env }>,
  key: string | null,
  filename: string,
): Promise<Response> {
  if (!key) return c.json({ ok: false, error: "Không có file." }, 404);
  const head = await c.env.MEDIA.head(key);
  if (!head) return c.json({ ok: false, error: "Không tìm thấy file." }, 404);
  const range = parseRange(c.req.header("Range") ?? null, head.size);
  const obj = range
    ? await c.env.MEDIA.get(key, {
        range: { offset: range.start, length: range.end - range.start + 1 },
      })
    : await c.env.MEDIA.get(key);
  if (!obj) return c.json({ ok: false, error: "Không tìm thấy file." }, 404);
  const headers: Record<string, string> = {
    "Content-Type": obj.httpMetadata?.contentType ?? "application/octet-stream",
    "Accept-Ranges": "bytes",
    "Cache-Control": "private, max-age=3600",
    "Content-Disposition": `inline; filename="${filename}"`,
  };
  if (range) {
    headers["Content-Range"] = `bytes ${range.start}-${range.end}/${head.size}`;
    headers["Content-Length"] = String(range.end - range.start + 1);
    return c.body(obj.body, 206, headers);
  }
  headers["Content-Length"] = String(head.size);
  return c.body(obj.body, 200, headers);
}

/** Playback: streams the media from R2 with Range support so AVPlayer can seek. */
app.get("/api/play/:id", async (c) => {
  const item = await getItem(c.env.DB, c.req.param("id"));
  if (!item || item.status !== "ready") {
    return c.json({ ok: false, error: "Item chưa sẵn sàng để phát." }, 404);
  }
  const ext = item.r2_key?.split(".").pop() ?? "mp4";
  return streamFromR2(c, item.r2_key, `${item.id}.${ext}`);
});

/** Thumbnail: same streaming, for the library grid. */
app.get("/api/thumb/:id", async (c) => {
  const item = await getItem(c.env.DB, c.req.param("id"));
  if (!item) return c.json({ ok: false, error: "Không tìm thấy item." }, 404);
  return streamFromR2(c, item.thumb_key, `${item.id}.jpg`);
});

/** Scrub-preview sprite: the tile grid of thumbnails the player crops per timestamp. */
app.get("/api/preview/:id", async (c) => {
  const item = await getItem(c.env.DB, c.req.param("id"));
  if (!item) return c.json({ ok: false, error: "Không tìm thấy item." }, 404);
  return streamFromR2(c, item.preview_key, `${item.id}.jpg`);
});

export default app;
