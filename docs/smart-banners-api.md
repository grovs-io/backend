# Smart Banners API

Design: `../docs/plans/2026-10-05-smart-banners-design.md` (backend repo root).

## SDK (`sdk.` host, standard SDK headers; web: `IDENTIFIER` must be a linked web domain)

### `POST /api/v1/sdk/authenticate`
Response gains `has_smart_banners` (boolean): any live banner in the project, and always `false` for iOS and Android. Skip the calls below when false.

The two endpoints below answer 422 `{"error":"Smart banners are web only"}` for any platform other than `web`.

### `GET /api/v1/sdk/smart_banners`
Live banners, `priority` asc then `id` asc. Cached 10 minutes per project; cleared on any change.

```json
{"smart_banners":[{"id":12,"platforms":["ios","android"],"url_include":["/products/*"],"url_exclude":[],
  "position":"top","title":"Get the app","subtitle":null,"button_text":"Open",
  "background_color":"#FFFFFF","text_color":"#111827","button_color":"#4F46E5","button_text_color":"#FFFFFF",
  "icon_url":null,"dismiss_days":7,"open_hide_days":30,"default_link":"https://example.sqd.link/abc123"}]}
```

### `POST /api/v1/sdk/smart_banners/:banner_id/link`
Body `{"page_path":"/products/42","data":{"product_id":"42"}}` → `{"link":"https://example.sqd.link/x9y8z7"}`.
Same payload (key order ignored) → same link. Stored link data is the canonical payload: `{"page_path": page_path, ...data}` with keys sorted; a `page_path` inside `data` wins.
Rules: `page_path` required, starts with `/`, 1–512 chars. `data` absent or `null` means `{}`; keys with `null` values are dropped; then ≤ 20 keys, keys ≤ 64 chars, values string ≤ 512 chars / finite number / boolean. The canonical payload's JSON is ≤ 4096 UTF-8 bytes. 422 `{"error":...}` otherwise.
404 for a non-live banner or one from another project (also when the banner is deleted mid-request). Past 10,000 page links per banner, the default link is returned; the cap is soft and may overshoot slightly under concurrent requests.
Creation limit: 120 new links/min per banner per IP; past that, 429 `{"error":"Too many new links for this banner from this IP — try again in a minute"}` with header `Retry-After: 60`. Existing-link lookups and the 10,000-link cap are never rate-limited; the cap keeps returning the default link (200).
Pages without link data use the banner's `default_link`; the SDK sends no request for them.
Banner links have no visitor (no referral credit), no preview, carry the reserved tag `smart_banner`, and are hidden from link lists (`links/search_v2`, `links/search`, MCP search), list metrics and CSV export; single-link lookups by id (server SDK `metrics_for_link`, automation `details_for_link`) still return them. They do count in project totals. Known gap: MCP `top_links` and the analytics explorer still list them.

### Events
Custom events through `events/batch`: `smart_banner_view`, `smart_banner_click`, `smart_banner_dismiss`, properties `{"smart_banner_id":12}`.

## Dashboard (`api.` host, Doorkeeper token, any project member)

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/api/v1/projects/:id/smart_banners` | | `{"smart_banners":[Banner]}` |
| GET | `/api/v1/projects/:id/smart_banners/:banner_id` | | `{"smart_banner":Banner}` |
| POST | `/api/v1/projects/:id/smart_banners` | `smart_banner[...]` | 201 `{"smart_banner":Banner}` |
| PATCH | `/api/v1/projects/:id/smart_banners/:banner_id` | `smart_banner[...]` | `{"smart_banner":Banner}` |
| DELETE | `/api/v1/projects/:id/smart_banners/:banner_id` | | `{}` |
| PATCH | `/api/v1/projects/:id/smart_banners/reorder` | `{"ids":[...]}` (every non-archived banner once) | `{"smart_banners":[Banner]}` |
| POST | `/api/v1/projects/:id/smart_banners/:banner_id/duplicate` | | 201 `{"smart_banner":Banner}` |

Write fields: `name, status, position, title, subtitle, button_text, background_color, text_color, button_color, button_text_color, dismiss_days, open_hide_days, platforms[], url_include[], url_exclude[], icon (file), remove_icon`. JSON or multipart. Blank array entries are dropped (send `url_include[]=` to clear in multipart). New banners go last.

`status` is `draft | live | paused | archived`, same lifecycle as in-app campaigns. Create accepts only `draft` (default) or `live`; update accepts any value. Archiving leaves `priority` untouched and drops the banner out of `reorder`'s required id list. Restoring an archived banner (updating its status away from `archived`) always lands on `paused`, appended to the end of the order (`priority` = max + 1), regardless of the status value sent.

`POST .../duplicate` copies every field and the icon into a new banner named `"<name> (copy)"`, status `draft`, appended to the end of the order, with its own default link.

`dismiss_days` hides the banner after the visitor closes it (×); `open_hide_days` hides it after the visitor taps Open. Both: integer, 0–365, default 7 and 30 respectively.

`Banner` adds `id, priority, icon_url, default_link, created_at, updated_at` and `stats` (`views, clicks, dismisses, ctr, opens, installs`; last 30 days; `installs` counts install + reinstall). `opens`/`installs` are counted from the events' `link_tags` (`smart_banner:<id>`, frozen at ingest), so they cover the default link and every page link.

Errors: 401 (token), 403 `{"error":"Forbidden"}`, 404 `{"error":...}`, 422 `{"error":"Validation failed: ..."}`.
Deleting a banner keeps its links working; they stay hidden.
Banner links (tagged `smart_banner`) cannot be edited, archived or deleted through the regular link endpoints (`api/v1/links`, MCP `links`) — 422.
Writes are recorded in the audit log (EE): `smart_banner.created`, `smart_banner.updated`, `smart_banner.deleted`, `smart_banner.reordered` (duplicate also records `smart_banner.created`).
