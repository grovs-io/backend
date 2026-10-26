# In-App Messaging API

Enterprise only. Design: `docs/plans/2026-09-28-in-app-messaging-foundation-design.md`. The format a device receives is fixed by `ee/config/in_app/definition.schema.json`.

## Switches

| Switch | Effect |
|---|---|
| `Instance#in_app_enabled?` | Plan gate. Off: dashboard routes answer 404, sync sends nothing |
| `in_app_settings.enabled` | Per project. Off: sync sends no campaigns |
| `IN_APP_ENABLED=false` | Global. Sync sends nothing, jobs do not run, batch responses carry no stamps |
| `IN_APP_PREVIEW_ORIGINS` | Self-hosting only. Comma-separated origins allowed to embed `GET /in_app/preview` (CSP `frame-ancestors` and the page's own postMessage check). Replaces the default (`REACT_HOST_PROTOCOL`+`REACT_HOST` and `REACT_BETA_HOST`) entirely when set |

Retention: the server's per-person view counts of a campaign (lifetime caps, answered-once) are deleted 30 days after it ends; its reports read analytics and are unaffected.

## Dashboard

Base: `/api/v1/projects/:id`. Token as for every dashboard call. A member of the instance can read, draft, edit, launch, pause, resume, end, send a test, update the audience and change settings.

| Call | Does | Answers |
|---|---|---|
| `GET /in_app_campaigns` | List, newest first. `status`, `limit` (up to 200), `after` (id of the last row) | 200 `{ in_app_campaigns, truncated, next_after }` |
| `POST /in_app_campaigns` | Create a draft | 201, 422 |
| `GET /in_app_campaigns/:campaign_id` | Read | 200, 404 |
| `PATCH /in_app_campaigns/:campaign_id` | Edit. A launched campaign gains a revision when what a device sees changes | 200, 403, 409, 422 |
| `DELETE /in_app_campaigns/:campaign_id` | Delete a draft | 200, 409 |
| `POST …/launch` | Draft to `live`, `scheduled` or, with a segment, `preparing` | 202, 409, 422 with the reason |
| `POST …/pause`, `…/resume`, `…/end` | Change state | 200, 409 |
| `POST …/duplicate` | Copy into a new draft. With `{ "variant": "b" }`, the copy holds that variant as its content and no experiment | 201, 422 |
| `POST …/images/:slot` | Upload `image` (PNG, JPEG or GIF, at most 1 MB). `slot` is `portrait` or `landscape` | 200, 422 |
| `DELETE …/images/:slot` | Remove | 200 |
| `GET …/media` | List files uploaded for use inside `html`. `{ media: [{ id, url, type, bytes, used }] }`; `used` is true when the address appears in the campaign's or a variant's `html` | 200 |
| `POST …/media` | Upload `file`: PNG/JPEG/GIF (≤ 1 MB), MP4 (≤ 20 MB), or MP3/M4A (≤ 10 MB), read from the bytes. At most 30 files and 100 MB per campaign. Optional `lock_version` form field: an older one answers `409` like a save | 201 `{ media: {…}, lock_version }`, 409, 422 |
| `DELETE …/media/:media_id` | Remove. Refused while the file's address is still in `html`. Optional `lock_version` param, checked as on upload | 200 `{ message: "Deleted", lock_version }`, 404, 409 (`{ "error": "in_use" }` or stale `lock_version`), 422 |
| `GET …/report` | `from`, `to` (dates, at most 92 days), `by` (`day` or `hour`) | 200, 422, 503 |
| `GET …/experiment` | `from`, `to`. The groups of an experiment, see Experiment | 200, 422, 503 |
| `GET /in_app_settings` | Read | 200 |
| `PATCH /in_app_settings` | `enabled`, `session_cap`, `day_cap`, `control_group` (0 to 20 percent of people who get no message at all), `push_daily_cap` (1 to 50 pushes per person per UTC day across every campaign and journey, or `null` for no cap) | 200, 422 |

### Campaign fields

| Field | Notes |
|---|---|
| `name` | Dashboard label |
| `template` | One of the ten in the schema, including `html` (see below). Cannot change after launch |
| `content`, `triggers`, `conditions`, `caps`, `schedule` | As in the schema. `schedule` holds `days`, `from`, `to` only |
| `start_at`, `end_at` | ISO 8601. No start means "at launch" |
| `priority` | 1 to 10 |
| `delay_seconds` | 0 to 3600 |
| `lock_version` | Optional on a save: the value the editor loaded. A save from an older one answers `409` and changes nothing |
| `audience` | `{ "type": "all" }` or `{ "type": "segment", "segment_id": "…" }`. Frozen at launch |
| `control_group` | 1 to 50, or null: the percent of the audience kept from the message. Fixed after launch |
| `conversion` | `{ "event": "checkout", "window_hours": 24 \| 72 \| 168 }` or `{ "screen": "Checkout", "window_hours": … }` or `{ "system": "reactivation", "window_hours": … }` (one of `install`, `reinstall`, `app_open`, `open` (link opened), `view` (link viewed) or `reactivation`) or `{ "purchase": true, "products": ["premium_month"], "window_hours": 24 \| 72 \| 168 \| 720 }` or null: a custom event, a screen view of that screen, that system event, or a store purchase (`buy`, renewals included; of one of `products` when given, 1 to 20 product ids), counts as a conversion when it follows exposure within the window. `products` is refused on other goals and 720 hours only applies to purchase goals. Message events (`in_app_*`, `push_open`) are refused |
| `variants` | Up to two `{ "id": "b" \| "c", "content": {…} }`, each a full content block for the campaign's template, or null. The campaign's own content is variant `a`. Their number and ids are fixed after launch; the content can change |

A draft may be incomplete. Launch, and every later save, checks the whole definition: the schema, 16 KB, unique button ids, end after start, no line break outside title and message, and `{{` only as a field.

### The `html` template

`content` carries `html` (string) and `layout` (`full`, `modal`, `banner_top`, `banner_bottom`); every other content field is present but ignored except `dismissible` and `backdrop`, which keep their usual meaning (backdrop tap on modal, swipe on banners). Only `close_button` is ignored: the SDK always draws its own close control for `html`, so a broken script can never trap a viewer.

- **Size:** `html` is checked raw, at most 64 KB of UTF-8 bytes (the schema's `maxLength` is a loose character bound only). The 16 KB definition limit is measured without `html`, so a large page does not count against it; each variant's `html` is checked the same way.
- **Link and resource rule:** a link (`a[href]`, `data-grovs-url`) is normalised (leading/trailing C0 controls and spaces stripped, every tab/LF/CR removed, scheme lowercased), then allowed as `https://<host>…`, `mailto:`, `tel:`, `sms:`, a `#fragment`, or any other custom scheme except `javascript`, `vbscript`, `data`, `blob`, `file`, `about`, `intent` and `http`. A resource (`src`, `poster`, `srcset`, `link[href]`, `url()` in `style`) must be `https:`, or `data:image/…` for an image. `<base>` and `<meta http-equiv="refresh">` are refused. `{{` inside any of these URL attributes is refused, since they are never filled with field values. An `<img>`/`<video>` with no size or `aspect-ratio` makes the builder show a warning (not an API error), since it only makes the message jump as it loads.
- Line breaks in `html` are allowed, and its own `{{` is never checked against the field syntax (the HTML may legitimately use `{{` in a script or framework).
- **Media:** uploaded through `…/media` (see above), not fetched until the message shows. `POST …/duplicate` copies only the files a copy's `html` (its own or a variant's) still references and rewrites their addresses; everything else uploaded is left behind. Media stays with the campaign and is purged when it is deleted.

#### Preview page

`GET /in_app/preview` on the API host (no auth, no project data) is a small static page built once at boot from `ee/config/in_app/preview.html` and the current `ee/config/in_app/bridge.js`. It has its own CSP (`frame-ancestors` restricted to the dashboard origins, no `X-Frame-Options`) and never appears in the dashboard's own routing. The dashboard embeds it (`new URL("/in_app/preview", config.apiUrl)`) and talks to it with `postMessage`:

- dashboard → page: `{ type: "render", seq, html, user, event, capabilities, layout, colorScheme }`
- page → dashboard: `{ type: "bridge", seq, message }` for every bridge envelope from the nested message frame, `ready` and `height` included
- dashboard → page: `{ type: "reply", seq, message }`, forwarded to the nested frame only while `seq` is still the page's current render

The page renders `html` into a nested `<iframe sandbox="allow-scripts" allow="autoplay; fullscreen" srcdoc>` that fills its viewport, with `bridge.js` injected exactly as the web SDK injects it (right after the doctype, as a plain `window.__grovs` assignment). Messages are accepted only from the parent window, and only when its origin is in the allowed list (see `IN_APP_PREVIEW_ORIGINS` above); messages from an already-replaced nested frame are dropped. Unlike the real SDKs, the preview does not tear a message down on self-navigation, so a nested message that navigates itself to an external page is still shown as-is in the preview; harmless, since the preview has no SDK state to protect.

The answer adds `id`, `status`, `revision`, `lock_version`, `launched_at`, `ended_at`, `failure_reason` and `audience.segment_changed`, which is true when the segment was edited after launch.

`failure_reason` after a campaign returns from `preparing` to `draft`: `audience_busy`, `segment_invalid`, `audience_error`.

Limits per project: 50 campaigns running at once, 20 segments targeted at once.

### Test message and audience update

`POST …/in_app_campaigns/:id/test` with `{ "identifier": "…" }` shows the message on every device of that person at its next sync within 30 minutes, whatever its triggers, conditions and limits. Nothing is counted. Answers `202 { "devices": 2 }`, or `422` when nobody has that identifier or the message is not complete.

`POST …/in_app_campaigns/:id/update_audience` moves a launched segment campaign to its segment as it is now. The old audience is served until the new one is written. Answers `202`, or `409` for a campaign with no audience to update.

### Report

```json
{ "report": {
  "totals": { "views": 4, "clicks": 2, "dismissals": 1, "unique_viewers": 3, "unique_clickers": 2, "click_rate": 0.5 },
  "trend": [ { "bucket": "2026-09-20", "views": 2, "clicks": 1, "dismissals": 0 } ],
  "platforms": [ { "platform": "ios", "views": 2, "clicks": 1, "dismissals": 0 } ],
  "buttons": [ { "button_id": "shop", "clicks": 1 }, { "button_id": null, "clicks": 1 } ],
  "eligible_devices": null
} }
```

`answers` is null for a campaign that asks no question. Otherwise:

```json
{ "type": "stars", "count": 3, "score": 4.0,
  "values": [ { "value": 1, "label": "1", "count": 0, "comments": 0 }, { "value": 5, "label": "5", "count": 2, "comments": 1 } ] }
```

`score` is the average for `stars` and null for `choice`.

`GET …/in_app_campaigns/:id/comments` takes `from`, `to`, an optional `values` (answers separated by commas, such as `1,2,3`) and an optional `before`, and answers 25 comments, newest first, with `next_before`: the cursor for the page after it, null at the end. Each entry of the report's `values` also carries `comments`, the number of comments for that answer.

`GET …/in_app_campaigns/:id/answers` takes the same `from` and `to` and answers every answer of the period, one row a person, newest first, at most 10,000 (`truncated` says when there were more): `at`, `platform`, `country`, `app_version`, `answer`, `label`, `comment`, `user`. It is what the dashboard's export writes to a file. `422` for a campaign that asks no question.

A click with no `button_id` is a tap on the message itself. `eligible_devices` counts devices, not people, and is null for audience `all`. Answers are cached for 60 seconds.

## Server API

The same campaigns from your own server with the instance API key, the credential of `POST /api/v1/sdk/server/push`. Host `sdk.<your-domain>`, base `/api/v1/sdk/server`, headers `PROJECT-KEY: <instance api key>` and `ENVIRONMENT: production|test` (the environment picks the project). Requests and answers are the dashboard's.

| Call | Does |
|---|---|
| `GET /in_app_campaigns`, `POST /in_app_campaigns` | List; create a draft |
| `GET`/`PATCH`/`DELETE /in_app_campaigns/:campaign_id` | Read, edit, delete a draft |
| `POST …/launch`, `…/pause`, `…/resume`, `…/end` | Change state |
| `POST …/test` | Show it to one person by `identifier` |
| `GET …/report` | Report |

Images go in the content as `https` URLs; uploads, media, answers, comments, experiments, duplicate, audience update and settings are dashboard-only and answer `404`. Writes are audited as the API key; `created_by` stays empty. Failures beyond the dashboard's: `400` missing `PROJECT-KEY` or bad `ENVIRONMENT`, `403` `Invalid credentials`, `403 enterprise_required` without an active paid plan (always on for self-hosted Enterprise), `429 rate_limited` (JSON, with `Retry-After`) over 120 requests a minute per key.

## SDK

### `POST /api/v1/sdk/in_app/sync`

Request: `{ "campaigns_changed_at": "…", "user_changed_at": "…", "format": 1, "sdk_version": "4.0.0" }`. The two stamps are the ones the device last received, or null.

When both match: `{ "unchanged": true, "server_time": "…", "store_url": "…" }`.

`store_url` is in every answer: the app's page in the App Store or Google Play, or null when the project has none or the platform is the web. `open_store` campaigns are skipped on a device that has no address.

Otherwise: the two stamps, `server_time`, `first_seen_at`, `global_caps`, `campaigns` and `test_messages`, which holds a message sent with "Send test" and is handed over once. `campaigns` holds the live and scheduled campaigns whose audience includes the visitor, without those whose end has passed and those whose lifetime cap the person has reached.

The stamps are opaque text. When Redis is down the stamps are left out and the device is never told "unchanged".

The response is gzipped (`Rack::Deflater`, scoped to this one endpoint) when the client sends `Accept-Encoding: gzip` — `html` campaigns shrink roughly 5x. No other endpoint compresses; self-hosted deployments behind a plain reverse proxy (SaaS already gets this from Cloudflare) benefit most.

### `POST /api/v1/sdk/events/batch`

Accepts `in_app_viewed`, `in_app_clicked`, `in_app_dismissed`, `in_app_answered` and `in_app_commented`. An answer must fit the campaign's question; a comment must hold words and at most 1,000 characters. Each is refused, alone, unless `campaign_id` is a launched campaign of the project and, for a click, `button_id` is absent or one of its buttons. A second answer from the same person, and a comment from someone who has not answered or for a question that asks for none, are refused. `POST /sdk/event/custom` refuses the five names.

An accepted view raises the person's total for the campaign. A view is recognised by its `event_id`, so a batch sent twice counts once; the last 100 ids per person and campaign are kept for this.

When a device gains an identifier (`POST /sdk/visitor_attributes`), the views it made while anonymous join that person's totals and the device is told to sync again.

Every answer carries `"in_app": { "campaigns_changed_at": "…", "user_changed_at": "…" }`. While in-app messages are switched off both stamps are `"off"`, so a device syncs at once and empties itself; the three in-app events are then refused.

A click whose `revision` is older than the campaign's may name a button that no longer exists.

## Jobs

| Job | When | Queue |
|---|---|---|
| `InAppCampaignTickJob` | Every minute | `maintenance` |
| `InAppMembershipPopulateJob` | At launch of a segment campaign | `egress_exports` |
| `InAppMembershipRefreshJob` | Hourly, one job per targeted segment | `egress_exports` |
| `InAppMembershipCleanupJob` | When a campaign ends, and nightly | `maintenance` |

Segment queries use the `in_app` permit lane: `SEGMENT_IN_APP_GLOBAL_PERMITS` (4) and `SEGMENT_IN_APP_PROJECT_PERMITS` (1).
