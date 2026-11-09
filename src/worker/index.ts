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
 * - GET  /api/list            ?platform=&q=&status=&limit=&cursor=
 * - GET  /api/items/:id       metadata for one item
 * - GET  /api/play/:id        streams the media from R2, Range/seek supported
 * - GET  /api/thumb/:id       streams the thumbnail from R2
 * - DELETE /api/items/:id     deletes R2 objects + D1 row
 * - POST /api/ingest-complete Bearer <INGEST_TOKEN>, called by the ingest service
 * - GET  /api/health          liveness probe, no auth
 *
 * Ingest contract (ingest service, NOT in this repo — Railway/Fly worker
 * running Cobalt / yt-dlp + ffmpeg):
 *   Worker -> ingest:  POST {INGEST_URL} { item_id, url }
 *                       Authorization: Bearer <INGEST_TOKEN>
 *   Ingest -> Worker:  POST /api/ingest-complete, same Bearer token, body:
 *     success: { item_id, r2_key, thumb_key?, preview_key?, content_type?,
 *                title?, caption?, author?, author_avatar_url?, posted_at?,
 *                duration?, width?, height?, file_size?, sha256? }
 *     failure: { item_id, error }
 *   Ingest uploads straight to R2 at
 *     users/<userId>/items/<itemId>/original.mp4 (and thumb.jpg / preview.mp4).
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
  deleteItem,
  detectPlatform,
  getItem,
  insertItem,
  listItems,
  markFailed,
  markReady,
  type IngestResult,
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

/** Save a link. Stores a pending row, then asks the ingest service to fetch it. */
app.post("/api/save", async (c) => {
  let body: unknown;
  try {
    body = await readJson(c);
  } catch {
    return c.json({ ok: false, error: "JSON không hợp lệ." }, 400);
  }
  const url = (body as { url?: unknown })?.url;
  if (typeof url !== "string" || !/^https?:\/\//i.test(url)) {
    return c.json({ ok: false, error: "url phải là link http(s)." }, 422);
  }
  const id = crypto.randomUUID();
  const userId = "me";
  const platform = detectPlatform(url);
  await insertItem(c.env.DB, { id, user_id: userId, platform, original_url: url });

  if (c.env.INGEST_URL) {
    // Fire-and-forget: a slow ingest must not block the save response.
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

  const item = await getItem(c.env.DB, id);
  return c.json({ ok: true, item, ingest_configured: Boolean(c.env.INGEST_URL) }, 202);
});

/** List saved items, newest first. cursor = base64 JSON {saved_at, id} from the last item. */
app.get("/api/list", async (c) => {
  const q = c.req.query("q") ?? undefined;
  const platform = c.req.query("platform") ?? undefined;
  const status = c.req.query("status") ?? undefined;
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

export default app;
