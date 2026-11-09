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
  author_avatar_url: string | null;
  posted_at: string | null;
  saved_at: string;
  duration: number | null;
  width: number | null;
  height: number | null;
  file_size: number | null;
  sha256: string | null;
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

export interface ListParams {
  userId: string;
  platform?: string;
  status?: string;
  q?: string;
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
  if (p.q) {
    // Escape LIKE wildcards so a search for "%" matches literally.
    const q = p.q.replace(/[%_\\]/g, (m) => `\\${m}`);
    where.push(
      `(title LIKE ${next()} ESCAPE '\\' OR caption LIKE ${next()} ESCAPE '\\' OR author LIKE ${next()} ESCAPE '\\')`,
    );
    binds.push(`%${q}%`, `%${q}%`, `%${q}%`);
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

export interface IngestResult {
  item_id: string;
  r2_key: string;
  thumb_key?: string | null;
  preview_key?: string | null;
  content_type?: string | null;
  title?: string | null;
  caption?: string | null;
  author?: string | null;
  author_avatar_url?: string | null;
  posted_at?: string | null;
  duration?: number | null;
  width?: number | null;
  height?: number | null;
  file_size?: number | null;
  sha256?: string | null;
}

export async function markReady(db: D1Database, r: IngestResult): Promise<void> {
  await db
    .prepare(
      `UPDATE items SET
         r2_key = ?1, thumb_key = ?2, preview_key = ?3, content_type = ?4,
         title = ?5, caption = ?6, author = ?7, author_avatar_url = ?8,
         posted_at = ?9, duration = ?10, width = ?11, height = ?12,
         file_size = ?13, sha256 = ?14, status = 'ready', ingest_error = NULL
       WHERE id = ?15`,
    )
    .bind(
      r.r2_key,
      r.thumb_key ?? null,
      r.preview_key ?? null,
      r.content_type ?? null,
      r.title ?? null,
      r.caption ?? null,
      r.author ?? null,
      r.author_avatar_url ?? null,
      r.posted_at ?? null,
      r.duration ?? null,
      r.width ?? null,
      r.height ?? null,
      r.file_size ?? null,
      r.sha256 ?? null,
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

export type { Env };
