# Grovs Event Stream API

Deliver every analytics and purchase event from a Grovs project to your own systems: an HTTPS endpoint (webhook), an S3-compatible bucket, or a feed your own job polls. A one-shot export covers history and gap repair.

- **Base URL:** `https://api.<your-domain>/api/v1`
- **Auth:** `Authorization: Bearer <token>`
- **Availability:** enterprise plans on Grovs Cloud, and the self-hosted enterprise image
- **Envelope version:** `schema_version: 1`
- **Retention:** 7 days

Use the numeric project ID from the dashboard API in request paths (`123` in the examples below). Destination IDs, feed-token IDs, and the envelope’s `project.id` are hashids; do not use the envelope’s `project.id` in a request path. Reads need project membership; every write needs an instance admin.

---

## Contents

- [Quickstart](#quickstart)
- [Guarantees](#guarantees)
- [Destinations](#destinations)
- [Destination actions](#destination-actions)
- [Exports](#exports)
- [Pull feed](#pull-feed)
- [Feed tokens](#feed-tokens)
- [Envelope v1](#envelope-v1)
- [Webhook delivery](#webhook-delivery)
- [S3 delivery](#s3-delivery)
- [Errors](#errors)
- [Operations](#operations)

---

## Quickstart

### 1. Create a destination

```bash
curl -X POST https://api.example.com/api/v1/projects/123/event_destinations \
  -H "Authorization: Bearer $DASHBOARD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "name": "Journey orchestration",
        "kind": "webhook",
        "settings": { "url": "https://hooks.acme.com/grovs" },
        "credentials": { "headers": { "X-Api-Key": "…" } },
        "event_types": ["install", "open", "custom", "purchase"],
        "batch_size": 100
      }'
```

### 2. Keep the signing secret

The response carries `signing_secret` exactly once. Store it before you close the window; it is never returned again. A lost secret is replaced by deleting the destination and creating another.

```json
{
  "event_destination": { "id": "gk3x", "status": "enabled", "lag_seconds": 0 },
  "signing_secret": "whsec_9f2c…"
}
```

### 3. Verify it end to end

```bash
curl -X POST https://api.example.com/api/v1/projects/123/event_destinations/gk3x/test \
  -H "Authorization: Bearer $DASHBOARD_TOKEN"

{ "message": "Test event delivered" }
```

> Capture begins when a project gets its first destination or feed token. Events from before that moment are only reachable through an [export](#exports).

---

## Guarantees

| | |
|---|---|
| **Delivery** | At least once. Deduplicate on the envelope `id`. |
| **Ordering** | Per device, across analytics and purchases. Different devices interleave. |
| **Latency** | About 15s while a destination is busy. An idle one resumes on the next minute tick. |
| **Replay** | Rewind within 7 days. Older gaps are repaired by an export. |

A destination holds a **bookmark**: the position up to which it has been offered every event. The bookmark only advances past events your endpoint accepted, so a failure resumes exactly where it stopped rather than skipping forward.

Purchases are corrected in place by the stores. Each correction arrives as a new envelope carrying a newer `purchase.version`. Within each project, upsert on (`purchase.transaction_id`, `name`), keeping the record with the newest `purchase.version`. The envelope’s `name` identifies the store action, so different actions for the same transaction remain separate records.

---

## Destinations

### `GET /projects/:project_id/event_destinations`

Role: **member**. Returns `{ "event_destinations": [ … ] }`. The fields below are also the shape of every single-destination response.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Hashid, used in every other path. |
| `name` | string | Your label for the destination. |
| `kind` | string | `webhook` or `s3`. Fixed at creation. |
| `status` | string | `enabled` or `paused`. |
| `paused_reason` | string, null | `manual`, or the automatic pause and when failures began. |
| `event_types` | array | The types this destination receives. |
| `batch_size` | integer | Webhook only: events per request, 1–500. |
| `concurrency` | integer | Webhook only: parallel requests, 1–16. Each covers a different device. |
| `include_ip` | boolean | Adds `geo.ip` and `geo.city` to the envelope. |
| `settings` | object | Transport configuration; see the create table. |
| `has_credentials` | boolean | Whether secrets are stored. The values are never returned. |
| `lag_seconds` | integer, null | How far behind the bookmark is right now. |
| `delivered_count` | integer | Events accepted since creation. |
| `last_delivered_at` | string, null | Last accepted delivery. |
| `last_attempt_at` | string, null | Last attempt, accepted or not. |
| `consecutive_failures` | integer | Resets on the first acceptance. |
| `last_error` | string, null | Response status only. Bodies are never stored. |
| `failing_since` | string, null | Start of the current failure run; 24 hours of it pauses the destination. |
| `backoff_until` | string, null | The next attempt is held until this moment. |
| `events_cursor_at` | string, null | Bookmark for analytics events. |
| `purchases_cursor_at` | string, null | Bookmark for purchase events. |
| `created_at`, `updated_at` | string | ISO 8601. |

### `POST /projects/:project_id/event_destinations`

Role: **admin**. Answers `201` with the object and its `signing_secret`.

| Parameter | Required | Notes |
|---|---|---|
| `name` | yes | Up to 255 characters. |
| `kind` | yes | `webhook` or `s3`. |
| `settings` | yes | Webhook: `url`. S3: `bucket`, `region`, optional `prefix`, `endpoint`, `force_path_style`. |
| `credentials` | depends | Webhook: `headers`, a map of strings. S3: `access_key_id` and `secret_access_key`, required on Grovs Cloud. |
| `event_types` | no | Defaults to every type except `time_spent` and `screen_view`. |
| `batch_size` | no | Default 100. |
| `concurrency` | no | Default 4. |
| `include_ip` | no | Default false. |

Event types: `view`, `open`, `install`, `reinstall`, `app_open`, `time_spent`, `reactivation`, `user_referred`, `screen_view`, `custom`, `purchase`.

> **Webhook URLs must be public HTTPS.** On Grovs Cloud a URL that resolves to a private or internal address is refused, and a custom S3 `endpoint` may use any S3-compatible provider, including Hetzner. The endpoint must use HTTPS and resolve to public addresses. At upload time, the final hostname (including the bucket for virtual-hosted addressing) is checked and its public IP is pinned for the connection.

### `PATCH /projects/:project_id/event_destinations/:id`

Role: **admin**. Takes any field from the create body except `kind`, which is fixed. Submitting `credentials` replaces what is stored.

> **Removing an event type gives up its backlog.** While a type is off, that stream's position follows the clock, so events during the window are not delivered when you turn it back on. Use an export to fetch them.

### `DELETE /projects/:project_id/event_destinations/:id`

Role: **admin**. When a project's last destination and last feed token are both gone, its captured rows are purged immediately.

---

## Destination actions

| Endpoint | Body | Result |
|---|---|---|
| `POST …/:id/pause` | — | Stops delivery and keeps the bookmark. |
| `POST …/:id/resume` | — | Continues from the bookmark and clears the failure count. |
| `POST …/:id/rewind` | `{ "to": "<iso8601>" }` | Moves both bookmarks back to re-deliver. Must be inside the last 7 days and not in the future. |
| `POST …/:id/test` | — | Sends one `{"type":"test"}` envelope through the live adapter. |

All are **admin**. Pause, resume and rewind answer `200` with the updated destination. The test action answers `200` on acceptance, `424` with the endpoint's status when it refuses, and `503` while delivery is paused platform-wide.

---

## Exports

### `POST /projects/:project_id/event_exports`

Role: **admin**. Answers `202`.

```json
{ "start_date": "2026-09-01", "end_date": "2026-09-30", "destination_id": "gk3x" }
```

Without `destination_id` the requester receives an email with a link to a gzip NDJSON file, valid for 24 hours. With it, the range is pushed through that destination, filtered by its event types, and may interleave with live deliveries, so deduplicate on `id` as usual. A push waits while the destination is paused or backing off, and resumes where it stopped after a failure. Purchases are included at their latest version.

The range is limited to 92 days and to your plan's retention window. A range that predates retention answers `422` with `"error_code": "retention_window_exceeded"`, which is worth distinguishing in the UI from an over-long range.

An export is the repair tool: when a destination has been paused past the 7-day window, the gap email names the exact range to request. It is sent at most once a day while the destination stays behind, each time covering everything skipped since the last one.

---

## Pull feed

### `GET /projects/:project_id/event_stream`

Auth: a feed token (`est_…`) or a dashboard token with project membership. The server stores nothing; you keep the cursor.

| Query | Default | Notes |
|---|---|---|
| `after` | — | The `next_after` from your last page. Omit to start 7 days back. |
| `limit` | 100 | 1–1000. Caps the page across analytics and purchases together. |
| `event_types[]` | all | Repeatable. |

```bash
curl "https://api.example.com/api/v1/projects/123/event_stream?limit=500" \
  -H "Authorization: Bearer est_4c1f…"

{
  "schema_version": 1,
  "events": [ … ],
  "next_after": "eyJlIjpbIjIwMjYtMDkt…"
}
```

Events come back merged in arrival order, so per-device ordering holds across the two streams. Pass `next_after` back as `after`; a malformed cursor answers `400`. Reads are limited to 120 a minute per token, and a token over that limit gets `503`.

---

## Feed tokens

Feed tokens carry the `est_` prefix and read one project. They are not dashboard credentials and cannot change anything.

| Endpoint | Role | Result |
|---|---|---|
| `GET …/event_stream_tokens` | admin | Active tokens: `id`, `name`, `created_at`, `last_used_at`, `created_by_email`. |
| `POST …/event_stream_tokens` | admin | `201` with the token value, shown once. Body: `{ "name": "warehouse" }`. |
| `DELETE …/event_stream_tokens/:id` | admin | Revokes it immediately. |

`last_used_at` is accurate to the minute, not to the request.

---

## Envelope v1

One JSON object per event, identical on every transport. New keys may appear; renames and removals come as a new `schema_version`.

```json
{
  "schema_version": 1,
  "id": "3f9a…",
  "type": "install",
  "name": null,
  "occurred_at": "2026-09-15T10:03:11.412Z",
  "project": { "id": "pQx7", "test": false },
  "link": {
    "id": 8812, "path": "summer", "campaign_id": 41,
    "source": "email", "medium": "newsletter", "campaign": "renewal",
    "ads_platform": null, "tags": ["q3"]
  },
  "attribution": { "link_visitor_id": "V1…", "inviter_id": null, "sdk_generated": false },
  "device": {
    "id": "D8…", "platform": "ios", "os": "iOS", "os_version": "18.6",
    "app_version": "3.11.0", "build": "12687", "model": "iPhone16,2",
    "timezone": "America/Chicago", "language": "en"
  },
  "user": { "id": "member-4471", "attributes": { "plan": "gold" } },
  "geo": { "country": "US" },
  "session_id": "s_…",
  "screen": "Home",
  "engagement_time": 0,
  "properties": {},
  "caused_by": null,
  "purchase": null
}
```

| Field | Notes |
|---|---|
| `id` | The deduplication key. For purchases it changes with every correction. |
| `type` | Any configured event type, plus `purchase` and `test`. |
| `name` | The custom event's name, or the store action for a purchase: `buy`, `cancel`, `refund`, `refund_reversed`. |
| `project.id`, `device.id`, `attribution.*` | Hashids, matching the dashboard. |
| `link.id`, `link.campaign_id` | Integers, the same ids the dashboard API returns. `link` is null when the event has none. |
| `user.id`, `user.attributes` | The identifier and attributes your app set through the SDK. This is the join key for a CRM or CDP. |
| `geo` | `country` only, unless the destination sets `include_ip`. |
| `session_id`, `screen`, `engagement_time`, `properties` | As recorded by the SDK. |
| `caused_by` | On `user_referred`, the id of the install that produced it. |
| `purchase` | On a purchase: `transaction_id`, `original_transaction_id`, `product_id`, `purchase_type`, `store`, `quantity`, `currency`, `usd_price_cents`, `purchase_date`, `version`. |

---

## Webhook delivery

One `POST` per batch, body `application/x-ndjson`: one envelope per line. Any `2xx` accepts the whole batch. Anything else is retried later from the same bookmark, so make the endpoint idempotent on `id`.

```
Content-Type: application/x-ndjson
User-Agent: Grovs-EventStream/1
X-Grovs-Destination: gk3x
X-Grovs-Batch: 2f1c…
X-Grovs-Signature: t=1789459200,v1=6c2a…
```

`v1` is `HMAC-SHA256(signing_secret, "<t>.<raw body>")`. Compare in constant time and reject a timestamp older than a few minutes.

```js
// Node
const [, t, v1] = req.get("X-Grovs-Signature").match(/t=(\d+),v1=([0-9a-f]+)/);
const expected = crypto.createHmac("sha256", secret).update(`${t}.${rawBody}`).digest("hex");
const ok = crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(v1));
```

```ruby
# Ruby
t, v1 = header.scan(/t=(\d+),v1=(\h+)/).first
expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{t}.#{raw_body}")
ok = ActiveSupport::SecurityUtils.secure_compare(expected, v1)
```

Redirects are not followed: a `3xx` counts as a failed delivery. Each request must finish within 40 seconds, and the response body is read but never stored. A destination that keeps failing backs off, and after 24 hours it pauses and emails the instance admins.

Throughput is yours to set. An endpoint that accepts one event per call should keep `batch_size` at 1 and raise `concurrency`; requests in flight always cover different devices, so per-device order survives.

---

## S3 delivery

One gzip NDJSON object per batch and event date:

```
<prefix>/project=<project id>/date=<YYYY-MM-DD>/<ms>-<event id>.ndjson.gz
```

The date is the event's own `occurred_at`, so a late event lands in its own day's partition rather than today's. S3 manages batching automatically; the webhook `batch_size` and `concurrency` settings do not apply. After catching up, a destination waits five minutes before checking for new events. A backlog continues on subsequent scheduler ticks (normally every minute), with each job yielding its worker after a bounded processing window. Failed deliveries follow their retry backoff instead of the idle interval. Snowflake, Databricks and BigQuery all ingest this layout directly. The credentials need `s3:PutObject` on the prefix and nothing else.

---

## Errors

Every error is `{ "error": "…" }`, except the retention refusal, which adds `error_code`.

| Status | Meaning | What to do |
|---|---|---|
| `400` | Malformed cursor or date. | Start a fresh page, or fix the value. |
| `401` | Missing, expired or revoked credential. | Re-authenticate, or issue a new feed token. |
| `402` | The instance is not on an enterprise plan. | Hide the feature, or prompt to upgrade. |
| `403` | Not an admin, or the resource belongs to another project. | Show it read-only for members. |
| `404` | No such destination or token. | Refresh the list. |
| `422` | Validation failed, or the export range is out of bounds. | Show `error`; branch on `error_code` for retention. |
| `424` | The test event reached your endpoint and it refused. | Show the status returned. |
| `503` | Throttled, or delivery is paused platform-wide. | Back off. Never retry automatically in a loop. |

---

## Operations

- Every destination change, token change, bookmark move and export request is written to the audit log.
- Self-hosted deployments run delivery in the `egress` worker role, sized with `SIDEKIQ_EGRESS_CONCURRENCY` (default 10). The combined `all-workers` role already serves it.
- `EVENT_STREAM_ENABLED=false` stops delivery, holds exports into destinations until it is lifted, and makes the test action answer `503`. Configuration endpoints stay up.
- Kafka, Azure Event Hubs, Kinesis, Pub/Sub and Adobe Experience Platform are additional destination types over the same pipeline. Ask if you need one.
