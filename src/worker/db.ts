import type { Env } from "./env";

export type Platform =
  | "tiktok"
  | "instagram"
  | "threads"
  | "x"
  | "facebook"
  | "douyin"
  | "youtube"
  | "other";

export interface Item {
  id: string;
  user_id: string;
  platform: Platform;
  original_url: string;
  r2_key: string | null;
  thumb_key: string | null;
  preview_key: string | null;
  content_type: string | null;
  title: string | null;
  caption: string | null;
  author: string | null;
  author_username: string | null;
  author_avatar_url: string | null;
  posted_at: string | null;
  saved_at: string;
  duration: number | null;
  width: number | null;
  height: number | null;
  file_size: number | null;
  sha256: string | null;
  preview_cols: number | null;
  preview_rows: number | null;
  preview_interval: number | null;
  preview_count: number | null;
  view_count: number | null;
  status: "pending" | "ready" | "failed";
  ingest_error: string | null;
  created_at: string;
}

export function detectPlatform(rawUrl: string): Platform {
  let host = "";
  try {
    host = new URL(rawUrl).hostname.toLowerCase();
  } catch {
    return "other";
  }
  if (host.includes("tiktok.com")) return "tiktok";
  if (host.includes("instagram.com")) return "instagram";
  if (host.includes("threads.net") || host.includes("threads.com")) return "threads";
  if (host === "x.com" || host.endsWith(".x.com") || host.includes("twitter.com"))
    return "x";
  if (host.includes("facebook.com") || host.includes("fb.watch")) return "facebook";
  if (host.includes("douyin.com")) return "douyin";
  if (host.includes("youtube.com") || host === "youtu.be") return "youtube";
  return "other";
}

export function r2Key(userId: string, itemId: string, name: string): string {
  return `users/${userId}/items/${itemId}/${name}`;
}

/**
 * Normalizes a saved URL before storing/comparing it, so the same link
 * pasted with different trailing slashes or surrounding whitespace does
 * not create a second copy. Only trailing slashes are stripped — the
 * scheme, host, path, and query are kept exactly as pasted.
 */
export function normalizeSaveUrl(rawUrl: string): string {
  return rawUrl.trim().replace(/\/+$/, "");
}

export async function insertItem(
  db: D1Database,
  item: Pick<Item, "id" | "user_id" | "platform" | "original_url">,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO items (id, user_id, platform, original_url, status)
       VALUES (?1, ?2, ?3, ?4, 'pending')`,
    )
    .bind(item.id, item.user_id, item.platform, item.original_url)
    .run();
}

export async function getItem(db: D1Database, id: string): Promise<Item | null> {
  const row = await db
    .prepare(`SELECT * FROM items WHERE id = ?1`)
    .bind(id)
    .first<Item>();
  return row ?? null;
}

/** Dedupe lookup for POST /api/save: the row for this exact (normalized) URL, if any. */
export async function findByUrl(db: D1Database, url: string): Promise<Item | null> {
  const row = await db
    .prepare(`SELECT * FROM items WHERE original_url = ?1 LIMIT 1`)
    .bind(url)
    .first<Item>();
  return row ?? null;
}

/** A previously failed save can be retried: back to pending, error cleared. */
export async function resetForRetry(db: D1Database, id: string): Promise<void> {
  await db
    .prepare(
      `UPDATE items SET status = 'pending', ingest_error = NULL WHERE id = ?1`,
    )
    .bind(id)
    .run();
}

export interface ListParams {
  userId: string;
  platform?: string;
  status?: string;
  q?: string;
  /** Filter to one collection. The sentinel "__unknown__" means NULL username. */
  authorUsername?: string;
  /** "video" = content_type starts with video/, "image" = starts with image/. */
  media?: string;
  limit: number;
  cursor?: { saved_at: string; id: string };
}

export async function listItems(
  db: D1Database,
  p: ListParams,
): Promise<Item[]> {
  const where: string[] = ["user_id = ?1"];
  const binds: unknown[] = [p.userId];
  let n = 1;
  const next = () => `?${++n}`;
  if (p.platform) {
    where.push(`platform = ${next()}`);
    binds.push(p.platform);
  }
  if (p.status) {
    where.push(`status = ${next()}`);
    binds.push(p.status);
  }
  if (p.authorUsername !== undefined) {
    if (p.authorUsername === "__unknown__") {
      where.push(`author_username IS NULL`);
    } else {
      where.push(`author_username = ${next()}`);
      binds.push(p.authorUsername);
    }
  }
  if (p.media === "video") {
    where.push(`content_type LIKE 'video%'`);
  } else if (p.media === "image") {
    where.push(`content_type LIKE 'image%'`);
  }
  if (p.q) {
    // Escape LIKE wildcards so a search for "%" matches literally.
    const q = p.q.replace(/[%_\\]/g, (m) => `\\${m}`);
    where.push(
      `(title LIKE ${next()} ESCAPE '\\' OR caption LIKE ${next()} ESCAPE '\\' OR author LIKE ${next()} ESCAPE '\\' OR author_username LIKE ${next()} ESCAPE '\\')`,
    );
    binds.push(`%${q}%`, `%${q}%`, `%${q}%`, `%${q}%`);
  }
  if (p.cursor) {
    where.push(`(saved_at, id) < (${next()}, ${next()})`);
    binds.push(p.cursor.saved_at, p.cursor.id);
  }
  const stmt = db
    .prepare(
      `SELECT * FROM items WHERE ${where.join(" AND ")}
       ORDER BY saved_at DESC, id DESC LIMIT ${next()}`,
    )
    .bind(...binds, p.limit + 1);
  const { results } = await stmt.all<Item>();
  return results ?? [];
}

export interface CollectionRow {
  author_username: string | null;
  author: string | null;
  count: number;
  cover_item_id: string | null;
  latest_saved_at: string;
}

/**
 * One collection per author username (NULL = author unknown), newest first.
 * `cover_item_id` is the newest item in the collection that has a thumbnail,
 * so the app can show a cover without a second query. `author` is the newest
 * display name seen for that username (MAX over the group is good enough —
 * the handle is the grouping key, the name is just a label).
 */
export async function listCollections(
  db: D1Database,
  userId: string,
): Promise<CollectionRow[]> {
  const { results } = await db
    .prepare(
      `SELECT
         author_username,
         MAX(author) AS author,
         COUNT(*) AS count,
         MAX(saved_at) AS latest_saved_at,
         (SELECT i2.id FROM items i2
            WHERE i2.user_id = items.user_id
              AND i2.author_username IS items.author_username
              AND i2.thumb_key IS NOT NULL
            ORDER BY i2.saved_at DESC, i2.id DESC LIMIT 1) AS cover_item_id
       FROM items
       WHERE user_id = ?1
       GROUP BY author_username
       ORDER BY latest_saved_at DESC`,
    )
    .bind(userId)
    .all<CollectionRow>();
  return results ?? [];
}

export interface IngestResult {
  item_id: string;
  r2_key: string;
  thumb_key?: string | null;
  preview_key?: string | null;
  content_type?: string | null;
  title?: string | null;
  caption?: string | null;
  author?: string | null;
  author_username?: string | null;
  author_avatar_url?: string | null;
  posted_at?: string | null;
  duration?: number | null;
  width?: number | null;
  height?: number | null;
  file_size?: number | null;
  sha256?: string | null;
  preview_cols?: number | null;
  preview_rows?: number | null;
  preview_interval?: number | null;
  preview_count?: number | null;
  view_count?: number | null;
}

export async function markReady(db: D1Database, r: IngestResult): Promise<void> {
  await db
    .prepare(
      `UPDATE items SET
         r2_key = ?1, thumb_key = ?2, preview_key = ?3, content_type = ?4,
         title = ?5, caption = ?6, author = ?7, author_username = ?8,
         author_avatar_url = ?9, posted_at = ?10, duration = ?11,
         width = ?12, height = ?13, file_size = ?14, sha256 = ?15,
         preview_cols = ?16, preview_rows = ?17, preview_interval = ?18,
         preview_count = ?19, view_count = ?20, status = 'ready', ingest_error = NULL
       WHERE id = ?21`,
    )
    .bind(
      r.r2_key,
      r.thumb_key ?? null,
      r.preview_key ?? null,
      r.content_type ?? null,
      r.title ?? null,
      r.caption ?? null,
      r.author ?? null,
      r.author_username ?? null,
      r.author_avatar_url ?? null,
      r.posted_at ?? null,
      r.duration ?? null,
      r.width ?? null,
      r.height ?? null,
      r.file_size ?? null,
      r.sha256 ?? null,
      r.preview_cols ?? null,
      r.preview_rows ?? null,
      r.preview_interval ?? null,
      r.preview_count ?? null,
      r.view_count ?? null,
      r.item_id,
    )
    .run();
}

export async function markFailed(
  db: D1Database,
  itemId: string,
  error: string,
): Promise<void> {
  await db
    .prepare(
      `UPDATE items SET status = 'failed', ingest_error = ?1 WHERE id = ?2`,
    )
    .bind(error.slice(0, 500), itemId)
    .run();
}

export async function deleteItem(db: D1Database, id: string): Promise<void> {
  await db.prepare(`DELETE FROM items WHERE id = ?1`).bind(id).run();
}

// ---------------------------------------------------------------------------
// My collections: user-created lists (TikTok-style "Add to collection").
// Unlike the per-creator collections (one per author username, automatic),
// these are lists the user creates and adds videos to by hand.
// ---------------------------------------------------------------------------

export interface MyCollection {
  id: string;
  user_id: string;
  name: string;
  created_at: string;
}

export interface MyCollectionRow {
  id: string;
  name: string;
  count: number;
  cover_item_id: string | null;
  created_at: string;
}

/**
 * User-created collections, newest first. `count` is the number of
 * videos in the collection; `cover_item_id` is the newest video with
 * a thumbnail, so the app can show a cover without a second query.
 */
export async function listMyCollections(
  db: D1Database,
  userId: string,
): Promise<MyCollectionRow[]> {
  const { results } = await db
    .prepare(
      `SELECT
         mc.id, mc.name, mc.created_at,
         COUNT(mci.item_id) AS count,
         (SELECT i2.id FROM my_collection_items m2
            JOIN items i2 ON i2.id = m2.item_id
            WHERE m2.collection_id = mc.id AND i2.thumb_key IS NOT NULL
            ORDER BY m2.added_at DESC, m2.item_id DESC LIMIT 1) AS cover_item_id
       FROM my_collections mc
       LEFT JOIN my_collection_items mci ON mci.collection_id = mc.id
       WHERE mc.user_id = ?1
       GROUP BY mc.id
       ORDER BY mc.created_at DESC, mc.id DESC`,
    )
    .bind(userId)
    .all<MyCollectionRow>();
  return results ?? [];
}

export async function getMyCollection(
  db: D1Database,
  id: string,
): Promise<MyCollection | null> {
  const row = await db
    .prepare(`SELECT * FROM my_collections WHERE id = ?1`)
    .bind(id)
    .first<MyCollection>();
  return row ?? null;
}

export async function createMyCollection(
  db: D1Database,
  c: Pick<MyCollection, "id" | "user_id" | "name">,
): Promise<void> {
  await db
    .prepare(`INSERT INTO my_collections (id, user_id, name) VALUES (?1, ?2, ?3)`)
    .bind(c.id, c.user_id, c.name)
    .run();
}

/** Adds a video to a collection. Returns false when it was already there. */
export async function addItemToMyCollection(
  db: D1Database,
  collectionId: string,
  itemId: string,
): Promise<boolean> {
  const res = await db
    .prepare(
      `INSERT OR IGNORE INTO my_collection_items (collection_id, item_id) VALUES (?1, ?2)`,
    )
    .bind(collectionId, itemId)
    .run();
  return (res.meta?.changes ?? 0) > 0;
}

export async function removeItemFromMyCollection(
  db: D1Database,
  collectionId: string,
  itemId: string,
): Promise<void> {
  await db
    .prepare(
      `DELETE FROM my_collection_items WHERE collection_id = ?1 AND item_id = ?2`,
    )
    .bind(collectionId, itemId)
    .run();
}

export async function deleteMyCollection(db: D1Database, id: string): Promise<void> {
  await db
    .prepare(`DELETE FROM my_collection_items WHERE collection_id = ?1`)
    .bind(id)
    .run();
  await db
    .prepare(`DELETE FROM my_collections WHERE id = ?1`)
    .bind(id)
    .run();
}

export interface MyCollectionItemRow extends Item {
  added_at: string;
}

/**
 * Videos in a collection, newest-added first. Keyset cursor is
 * { added_at, item_id } of the last row (same pattern as listItems).
 * The extra `added_at` field is returned per row so the endpoint can
 * build the next cursor; the iOS Item decoder ignores unknown keys.
 */
export async function listMyCollectionItems(
  db: D1Database,
  p: {
    collectionId: string;
    limit: number;
    cursor?: { added_at: string; item_id: string };
  },
): Promise<MyCollectionItemRow[]> {
  const where: string[] = ["mci.collection_id = ?1"];
  const binds: unknown[] = [p.collectionId];
  let n = 1;
  const next = () => `?${++n}`;
  if (p.cursor) {
    where.push(`(mci.added_at, mci.item_id) < (${next()}, ${next()})`);
    binds.push(p.cursor.added_at, p.cursor.item_id);
  }
  const stmt = db
    .prepare(
      `SELECT items.*, mci.added_at AS added_at
       FROM my_collection_items mci
       JOIN items ON items.id = mci.item_id
       WHERE ${where.join(" AND ")}
       ORDER BY mci.added_at DESC, mci.item_id DESC LIMIT ${next()}`,
    )
    .bind(...binds, p.limit + 1);
  const { results } = await stmt.all<MyCollectionItemRow>();
  return results ?? [];
}

export type { Env };
