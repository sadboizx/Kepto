-- Kepto v2: per-username collections + scrub-preview sprites.
-- Applied with: wrangler d1 migrations apply kepto-items
-- (dashboard: paste the comment-free single-line version in the D1 Console —
-- a paste can lose newlines, and a `--` comment would swallow the script.)
--
-- author_username: creator handle (e.g. nana.cat42) from ingest metadata.
--   The app groups saved items into one collection per username, like
--   TikTok's Collections tab. NULL = author unknown ("Unknown" collection).
-- preview_cols/rows/interval/count: geometry of the scrub-preview sprite
--   (preview_key now stores users/<userId>/items/<itemId>/sprite.jpg,
--   a tile grid of thumbnails; interval = seconds between frames).
-- idx_items_original_url: supports the dedupe check in POST /api/save.

ALTER TABLE items ADD COLUMN author_username TEXT;
ALTER TABLE items ADD COLUMN preview_cols INTEGER;
ALTER TABLE items ADD COLUMN preview_rows INTEGER;
ALTER TABLE items ADD COLUMN preview_interval REAL;
ALTER TABLE items ADD COLUMN preview_count INTEGER;

CREATE INDEX IF NOT EXISTS idx_items_author_username ON items(author_username);
CREATE INDEX IF NOT EXISTS idx_items_original_url ON items(original_url);
