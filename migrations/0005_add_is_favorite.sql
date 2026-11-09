ALTER TABLE items ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_items_favorite ON items(user_id, is_favorite);
