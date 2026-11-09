-- Kepto items table (Cloudflare D1).
-- Applied with: wrangler d1 migrations apply kepto-items
-- (local dev: wrangler d1 migrations apply kepto-items --local)
--
-- R2 holds bytes only; everything searchable lives here.
-- status: pending (saved, ingest not done) | ready (media in R2)
--         | failed (ingest error, see ingest_error)

CREATE TABLE IF NOT EXISTS items (
  id                TEXT PRIMARY KEY,              -- crypto.randomUUID()
  user_id           TEXT NOT NULL DEFAULT 'me',    -- single-user MVP; real auth later
  platform          TEXT NOT NULL,                 -- tiktok|instagram|threads|x|facebook|douyin|youtube|other
  original_url      TEXT NOT NULL,
  r2_key            TEXT,                          -- users/<userId>/items/<itemId>/original.mp4
  thumb_key         TEXT,                          -- users/<userId>/items/<itemId>/thumb.jpg
  preview_key       TEXT,                          -- users/<userId>/items/<itemId>/preview.mp4
  content_type      TEXT,                          -- video/mp4, image/jpeg, ...
  title             TEXT,
  caption           TEXT,
  author            TEXT,
  author_avatar_url TEXT,
  posted_at         TEXT,                          -- original post time, ISO 8601
  saved_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  duration          REAL,                          -- seconds, video only
  width             INTEGER,
  height            INTEGER,
  file_size         INTEGER,                       -- bytes
  sha256            TEXT,
  status            TEXT NOT NULL DEFAULT 'pending',
  ingest_error      TEXT,
  created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_items_user_saved ON items(user_id, saved_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_items_platform ON items(platform);
CREATE INDEX IF NOT EXISTS idx_items_status ON items(status);
CREATE INDEX IF NOT EXISTS idx_items_author ON items(author);
