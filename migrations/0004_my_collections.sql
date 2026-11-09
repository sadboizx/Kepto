-- Kepto v13: user-created collections ("My collections"), like TikTok's
-- Add to collection. The per-creator collections (GET /api/collections)
-- stay automatic; these are lists the user creates and adds videos to.
-- Applied with: wrangler d1 migrations apply kepto-items
-- (dashboard: paste the comment-free single-line version in the D1 Console —
-- a paste can lose newlines, and a `--` comment would swallow the script.)

CREATE TABLE IF NOT EXISTS my_collections (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS my_collection_items (collection_id TEXT NOT NULL, item_id TEXT NOT NULL, added_at TEXT NOT NULL DEFAULT (datetime('now')), PRIMARY KEY (collection_id, item_id));
CREATE INDEX IF NOT EXISTS idx_my_collections_user ON my_collections(user_id);
CREATE INDEX IF NOT EXISTS idx_my_collection_items_collection ON my_collection_items(collection_id);
CREATE INDEX IF NOT EXISTS idx_my_collection_items_item ON my_collection_items(item_id);
