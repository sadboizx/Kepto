export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  /** Bearer token the iOS app sends. Set with `wrangler secret put KEPTO_API_KEY`. */
  KEPTO_API_KEY: string;
  /** Bearer token the ingest service sends on /api/ingest-complete. */
  INGEST_TOKEN: string;
  /** Ingest service URL (Railway/Fly). Empty until the service exists. */
  INGEST_URL: string;
}
