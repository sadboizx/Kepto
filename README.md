# Kepto — backend

Cloud-only social archive. iOS app là thin client: gửi link, ingest service tải
media thật + metadata về R2, app phát lại từ R2. Bài gốc xóa sau đó cũng không
ảnh hưởng — bản sao đã nằm trong bucket của bạn.

Tên repo: Kepto. Tên hiển thị trên App Store chưa chốt — đã có app Kepto khác
làm save-later, nên tên app có thể đổi trước khi làm UI.

## Stack

- Cloudflare Workers (Hono) — API
- D1 `kepto-items` — metadata, search, collection (R2 chỉ giữ bytes)
- R2 `kepto-media` — file gốc, bucket private, egress $0
- Ingest service (chưa có trong repo này) — Railway/Fly worker chạy
  Cobalt / yt-dlp + ffmpeg, upload thẳng lên R2

## Endpoints

Tất cả `/api/*` (trừ `/api/health`) cần `Authorization: Bearer <KEPTO_API_KEY>`.

| Method | Path | Ghi chú |
| --- | --- | --- |
| POST | `/api/save` | `{ url }` → 202, item `pending`, gọi ingest nền |
| GET | `/api/list?platform=&q=&status=&limit=&cursor=` | Mới nhất trước, tìm theo tiêu đề/caption/tác giả |
| GET | `/api/items/:id` | Metadata 1 item |
| GET | `/api/play/:id` | Stream media từ R2, hỗ trợ Range để AVPlayer seek |
| GET | `/api/thumb/:id` | Stream thumbnail |
| DELETE | `/api/items/:id` | Xóa file R2 + row D1 |
| POST | `/api/ingest-complete` | Ingest service callback, Bearer `<INGEST_TOKEN>` |
| GET | `/api/health` | Không cần auth |

## Bucket layout

```
users/<userId>/items/<itemId>/original.mp4
users/<userId>/items/<itemId>/thumb.jpg
users/<userId>/items/<itemId>/preview.mp4
```

## Secrets

Không có secret nào trong code. `KEPTO_API_KEY` và `INGEST_TOKEN` đặt bằng
`wrangler secret put …`, local dev để trong `.dev.vars` (đã gitignore).
Xem phần Setup trong `wrangler.toml`.
