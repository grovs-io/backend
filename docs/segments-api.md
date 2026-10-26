# Grovs Segments API

Define a reusable **segment** of your users — by device/app fields, profile attributes, custom
and built-in events, acquisition, purchases, or an uploaded identifier list — then see how many
people match it, list and export them, split them by a dimension, and filter other analytics
pages by it.

- **Base URL:** `https://api.<your-domain>/api/v1`
- **Auth:** `Authorization: Bearer <token>` (dashboard token)
- **Availability:** every plan on Grovs Cloud, and the self-hosted enterprise image (absent
  from the open-source image). Requires ClickHouse reads and writes to be enabled.

Use the numeric project ID from the dashboard API in request paths (`123` in the examples below).
Segment ids and export ids are hashids; do not use them in place of the project id.

---

## Contents

- [Quickstart](#quickstart)
- [Authentication and roles](#authentication-and-roles)
- [The definition format](#the-definition-format)
- [Condition types](#condition-types)
- [Limits](#limits)
- [Endpoints](#endpoints)
- [Identifier lists](#identifier-lists)
- [Exports](#exports)
- [Size and size history](#size-and-size-history)
- [Semantics](#semantics)
- [Server API](#server-api)
- [Errors](#errors)

---

## Quickstart

### 1. Create a segment

```bash
curl -X POST https://api.example.com/api/v1/projects/123/segments \
  -H "Authorization: Bearer $DASHBOARD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "name": "iOS pro buyers",
        "definition": {
          "version": 1,
          "operator": "and",
          "groups": [
            { "operator": "and", "conditions": [
              { "type": "device", "field": "platform", "op": "is", "value": ["ios"], "mode": "current" },
              { "type": "purchase", "product_id": ["pro_yearly"], "count": 1, "window": {"last_days": 90} }
            ]}
          ]
        }
      }'
```

### 2. Get an exact count

```bash
curl -X POST https://api.example.com/api/v1/projects/123/segments/gk3x/count \
  -H "Authorization: Bearer $DASHBOARD_TOKEN"

{ "persons": 4821, "devices": 5310, "incomplete": false, "result_id": "3f9a…" }
```

`count` (and `users`, `breakdown`) evaluate the segment once into a short-lived result and reuse
it; the first call after a definition changes can take a few seconds, later calls in the same
window are instant.

### 3. List members

```bash
curl -X POST https://api.example.com/api/v1/projects/123/segments/gk3x/users?limit=50 \
  -H "Authorization: Bearer $DASHBOARD_TOKEN"
```

---

## Authentication and roles

Any member of the project's instance (`InstanceRole`, admin or member) can use every segments
endpoint, the same as every other project-scoped dashboard endpoint; anyone else gets `403`.

---

## The definition format

```json
{
  "version": 1,
  "operator": "or",
  "groups": [
    { "operator": "and", "conditions": [
      { "type": "device", "field": "platform", "op": "is", "value": ["ios"], "mode": "current" },
      { "type": "purchase", "product_id": ["pro_yearly"], "count": 1, "window": {"last_days": 90} }
    ]},
    { "operator": "and", "conditions": [
      { "type": "event", "event_name": "checkout",
        "filters": [{"field": "properties.plan", "op": "is", "value": "pro"}],
        "count": 3, "window": {"last_days": 30} }
    ]}
  ]
}
```

- Two levels: a top-level `operator` (`and`/`or`) combines **groups**, each group's own
  `operator` combines its **conditions**. A group cannot contain another group.
- `version` must be `1`.
- 1–5 groups, 1–10 conditions per group.
- A **window** is either rolling — `{"last_days": N}` — or fixed — `{"from": "YYYY-MM-DD", "to":
  "YYYY-MM-DD"}`. Both are UTC and day-aligned. A fixed window cannot start in the future, cannot
  span more than the condition's cap, and is clamped to your plan's data retention (see
  [Semantics](#semantics)).
- Saving a definition re-serializes it into a canonical form (sorted keys, defaults filled in);
  `definition_hash` is a digest of that canonical form, used to key size history and to detect
  whether a segment's definition has changed since a snapshot.

---

## Condition types

| Type | Matches | Notes |
|---|---|---|
| `event` | A built-in event type, a custom event name, or any activity | `count` (default 1), optional `filters`, `window`, `negate` |
| `device` | Device/app fields | `mode: "current"` (argMax over the last 30 days) or `"used"` (any matching event in a window) |
| `profile` | A visitor's current profile attribute | `properties.<key>` only |
| `first_seen` | The person's earliest built-in event | `gte`/`lte` on an ISO date |
| `identifier` | The person's `sdk_identifier` | presence, exact, contains, or list membership |
| `acquisition` | The install/reinstall that brought the person in | link, campaign, source, medium |
| `purchase` | Transactions | needs `revenue_collection_enabled` on the instance |

### `event`

Give exactly one of `event_type`, `event_name`, or `any: true`.

```json
{ "type": "event", "event_type": "app_open", "count": 3, "window": {"last_days": 90} }
```

```json
{ "type": "event", "event_name": "checkout",
  "filters": [{"field": "properties.plan", "op": "is", "value": "pro"}],
  "count": 1, "window": {"last_days": 30}, "negate": false }
```

`filters` (up to 25) accept `is` / `is_not` / `contains` over `screen_name`, `platform`,
`app_version`, `country`, `city`, `device_model`, `os`, `os_version`, `language`,
`tracking_source`, `tracking_medium`, `tracking_campaign`, `ads_platform`, or
`properties.<key>`. Max window: 90 days (`SEGMENT_EVENT_LOOKBACK_DAYS`, env-tunable).

### `device`

```json
{ "type": "device", "field": "platform", "op": "is", "value": ["ios"], "mode": "current" }
```

```json
{ "type": "device", "field": "os_version", "op": "is", "value": ["18.6"],
  "mode": "used", "window": {"last_days": 30} }
```

Fields: `platform`, `os`, `os_version`, `app_version`, `device_model`, `language`, `country`. Ops:
`is`, `is_not`, `contains`. `mode: "current"` needs no window (fixed at the last 30 days); `mode:
"used"` needs one, up to the `event` cap. `is_not` means "not seen with that value in the window",
so a person with no activity in it also matches; the same holds for `profile` `is_not` without a
profile row.

### `profile`

```json
{ "type": "profile", "field": "properties.plan", "op": "is", "value": ["pro"] }
```

Ops: `is`, `is_not`, `contains`, `is_set`, `is_not_set` (the last two take no `value`). Reads the
visitor's **current** `user_profiles.properties`, not an event-time snapshot.

### `first_seen`

```json
{ "type": "first_seen", "op": "gte", "value": "2026-01-01" }
```

`op` is `gte` or `lte`; `value` is an ISO date. Only built-in events set first-seen — a person
whose only activity is custom events never matches.

### `identifier`

```json
{ "type": "identifier", "op": "is", "value": ["member-4471"] }
```

```json
{ "type": "identifier", "op": "in_list" }
```

Ops: `is_set`, `is_not_set`, `is` (exact match), `contains` (case-insensitive substring),
`in_list` / `not_in_list` (need a saved segment with an uploaded identifier list; `not_in_list` is a
negative condition, so it must sit in an `and` group with a positive one — see
[Identifier lists](#identifier-lists); refused on an unsaved draft).

### `acquisition`

```json
{ "type": "acquisition", "field": "campaign_id", "op": "is", "value": [41], "window": {"last_days": 365} }
```

```json
{ "type": "acquisition", "field": "tracking_source", "op": "is", "value": ["email"] }
```

`field` is `link_id`/`campaign_id` (integer ids, ops `is`/`is_not`) or
`tracking_source`/`tracking_medium` (string, ops `is`/`is_not`/`contains`). Matches any
install/reinstall event in the window. Default window 365 days if omitted (clamped to your plan's
retention); max 365 days.

### `purchase`

```json
{ "type": "purchase", "product_id": ["pro_yearly"], "purchase_type": ["subscription"],
  "count": 1, "min_total_usd_cents": 999, "window": {"last_days": 90} }
```

Optional `product_id`, `purchase_type` (`subscription`/`one_time`), `store_source` lists;
`count` (default 1, at least N eligible transactions); `min_total_usd_cents` (default 0);
`window` applies to the purchase's date, max 365 days. See
[Semantics](#semantics) for how a transaction counts.

---

## Limits

| Limit | Value |
|---|---|
| Groups per definition | 5 |
| Conditions per group | 10 |
| Filters per `event` condition | 25 |
| Values per filter/list | 100 |
| Value length | 256 bytes |
| Identifiers per uploaded list | 200,000 |
| `event`/`device` window | 90 days |
| `acquisition`/`purchase` window | 365 days |

The window caps are env-tunable server-side; the other limits are fixed. Call
`GET /segments/fields` to read the limits and field catalogue your instance is running with.

---

## Endpoints

All paths are under `/projects/:project_id`.

| Endpoint | Role | Purpose |
|---|---|---|
| `GET /segments?archived=` | member | List segments (see [Size and size history](#size-and-size-history)) |
| `POST /segments` | member | Create |
| `GET /segments/:segment_id` | member | Show one |
| `PATCH /segments/:segment_id` | member | Update name/description/definition/`archived` |
| `DELETE /segments/:segment_id` | member | Archive (soft-delete) |
| `GET /segments/fields` | member | Field and operator catalogue, and current limits |
| `POST /segments/estimate` | member | Estimate a draft `definition`, an existing `segment_id`, or both (a draft edit of that segment, backed by its identifier list) |
| `POST /segments/:segment_id/count` | member | Exact count |
| `POST /segments/:segment_id/users` | member | Paginated members |
| `POST /segments/:segment_id/breakdown` | member | Split members by a dimension |
| `GET /segments/:segment_id/size_history` | member | Daily size snapshots |
| `POST /segments/:segment_id/identifier_list` | member | Upload/replace the identifier list |
| `POST /segments/:segment_id/export` | member | Start a CSV export |
| `GET /segment_exports` | member | List recent exports |
| `GET /segment_exports/:export_id` | member | Export status and download URL |

### `GET /segments`

```json
{
  "segments": [{
    "id": "gk3x", "name": "iOS pro buyers", "description": null,
    "definition": { "...": "..." }, "definition_hash": "a1b2…", "archived": false,
    "identifier_list": { "count": 4821, "updated_at": "2026-09-23T10:00:00.000Z" },
    "has_identifier_list": true,
    "size": { "date": "2026-09-17", "persons": 4821, "devices": 5310 },
    "created_at": "2026-09-01T10:00:00Z", "updated_at": "2026-09-17T04:00:12Z"
  }],
  "truncated": false
}
```

Returns at most 200 segments, most recently updated first; `truncated: true` means there are
more. `size` is the latest daily snapshot **within the last 7 days for the current
definition** — `null` if the segment is new, was just edited, or archived long ago.

### `POST /segments/estimate`

Body: `{ "definition": {...} }` (a draft), `{ "segment_id": "gk3x" }` (an existing one), or both
`{ "definition": {...}, "segment_id": "gk3x" }` (a draft edit of that segment: the draft is what gets
estimated, and the segment's uploaded identifier list backs its `in_list` / `not_in_list`; an unknown
or archived `segment_id` is `404`).

`has_identifier_list` and `identifier_list` on a segment derive from the same upload: the flag is kept
for older clients, the object adds `count` and `updated_at` (both `null` for lists uploaded before
2026-09-23, until the next upload).

```json
{ "persons": 4821, "devices": 5310, "approximate": false, "incomplete": false }
```

Counts are exact (`approximate` is always `false` today — reserved for a future faster mode).
`incomplete: true` means part of the window falls outside your data retention, so the true count
may be undercounted (or, for a negative condition, the request is refused — see
[Semantics](#semantics)).

### `POST /segments/:segment_id/count`

```json
{ "persons": 4821, "devices": 5310, "incomplete": false, "result_id": "3f9a1c2e…" }
```

`result_id` pins the computed result; pass it to `users` (first page) and `breakdown` so they read the
same snapshot instead of computing again. A result is reused for the same definition for a few
minutes and kept for a couple of hours.

### `POST /segments/:segment_id/users`

Query/body: `cursor` (from a previous page), `limit` (default 50, max 200), `q` (optional, up to 100
characters: case-insensitive substring of the identifier or prefix of the device uuid; the cursor
carries it, so later pages keep the same filter and `persons`/`devices` stay the unfiltered totals),
`result_id` (optional on the first page: reuse the result `count` returned instead of computing a
fresh one; `410` if it expired or belongs to an older definition). On later pages the cursor's own
`q` wins over a `q` parameter, so a filter can never be dropped mid-pagination.

```json
{
  "users": [{ "id": "D8…", "uuid": "…", "sdk_identifier": "member-4471", "sdk_attributes": {},
              "inviter_id": null, "web_visitor": false, "created_at": "…", "updated_at": "…",
              "person_key": "i:member-4471" }],
  "next_cursor": "eyJyIjoiM2Y5YT…",
  "result_id": "3f9a1c2e…", "persons": 4821, "devices": 5310, "incomplete": false
}
```

One row per effective visitor (device). `person_key` is `i:<sdk_identifier>` for an identified
person, `v:<visitor_id>` otherwise. Pass `next_cursor` back as `cursor` for the next page; a page
can come back shorter than `limit` with a cursor still set.

### `POST /segments/:segment_id/breakdown`

Body: `{ "by": "platform" }`, optionally `{ "result_id": "…" }` to reuse a specific pinned result.

```json
{
  "by": "platform", "total_persons": 4821, "result_id": "3f9a1c2e…",
  "buckets": [
    { "value": "ios", "label": "ios", "persons": 4200 },
    { "value": "android", "label": "android", "persons": 500 },
    { "value": "other", "label": "other", "persons": 60 },
    { "value": "unknown", "label": "unknown", "persons": 61 }
  ]
}
```

`by` is one of `platform`, `country`, `app_version`, `source`, `campaign`, `first_seen_week`, or
`properties.<key>`. One value per person (buckets are exclusive and sum to `total_persons`); top
50 buckets plus `other`; persons with no value land in `unknown`.

---

## Identifier lists

```bash
curl -X POST https://api.example.com/api/v1/projects/123/segments/gk3x/identifier_list \
  -H "Authorization: Bearer $DASHBOARD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "identifiers": ["member-4471", "member-9021"] }'

{ "segment": { "...": "..." }, "count": 2 }
```

Or upload a CSV file as `multipart/form-data` (`file` field; any row whose first cell is
`identifier`, case-insensitively, is skipped; a malformed file gets `422`). Between 1 and 200,000 identifiers, each 1–256 bytes, stored exactly
as sent. A second upload for the same segment while one is running gets `409`; a failed upload
leaves the previously published list untouched. Use an `identifier` condition with `op:
"in_list"` to match against it.

---

## Exports

```bash
curl -X POST https://api.example.com/api/v1/projects/123/segments/gk3x/export \
  -H "Authorization: Bearer $DASHBOARD_TOKEN"

{ "export": { "id": "ex91", "segment_id": "gk3x", "status": "pending", "rows": null,
              "definition_hash": "a1b2…", "error": null, "download_url": null,
              "created_at": "…", "updated_at": "…" } }
```

Poll `GET /segment_exports/:export_id` until `status` is `ready` (or `failed`). The export
captures the segment's definition and identifier list at request time, so an edit made while it
is queued does not change the file.

```json
{ "export": { "id": "ex91", "status": "ready", "rows": 4821, "definition_hash": "a1b2…",
              "error": null, "download_url": "https://.../file?sig=…", "created_at": "…", "updated_at": "…" } }
```

`download_url` is a **signed link, valid for 5 minutes**, minted fresh on each authenticated
request to `export_status` — it is not the file's permanent location. No download link is ever
included in the completion e-mail. Files are deleted 24 hours after the export completes, whether or
not they were downloaded. An export that could not get an evaluation slot is retried a few times
over the next half hour before it is marked `failed`. On self-hosted deployments using a private S3/MinIO endpoint, the
presigned URL may not be reachable from the customer's browser — confirm the storage endpoint is
publicly reachable before enabling exports there.

---

## Size and size history

Once a day, starting around 04:00 UTC, each active (non-archived) segment gets a size estimate
(persons/devices). The run is spread out, and a segment that is too heavy or whose estimate fails
that day has no point for that day. Each estimate is stored as a daily snapshot tagged with the
definition it was computed against.

`GET /segments/:segment_id/size_history` returns up to the newest 180 daily snapshots **for the
segment's current definition only** — editing a definition starts a fresh history line, it does
not retroactively relabel old snapshots.

```json
{ "size_history": [
  { "date": "2026-09-17", "persons": 4821, "devices": 5310, "incomplete": false },
  { "date": "2026-09-16", "persons": 4790, "devices": 5270, "incomplete": false }
]}
```

`GET /segments` surfaces only the most recent of these (`size`), and only if it is within the
last 7 days — a stale or missing snapshot renders as `size: null`.

---

## Filtering analytics by a segment

The events explorer (list and volume), the sessions list, and the retention summary all accept an
optional `segment_id` query parameter, scoping the surface to that segment's members. It is
ignored (has no effect) on the open-source image. The first request against a segment
materializes its result, which can take a few seconds; later requests in the same window are
fast. A segment filter counts toward the host endpoint's own heavy-query range caps.

Errors specific to the filter:

| Status | `error_code` | Meaning |
|---|---|---|
| `404` | — | Unknown, archived, or cross-project segment |
| `429` | `segment_busy` | Retry shortly — **not** the `503` back-off signal other analytics endpoints use |
| `422` | `invalid_segment` | The segment's stored definition no longer parses, or a "did not" condition's window aged past retention |

---

## Semantics

- **A user is a person.** The unit of every count is a person: the visitor's `sdk_identifier`
  exactly as your app sent it — case- and whitespace-sensitive, `UserA` and `usera` are different
  people — when one was set, otherwise the visitor itself. A matching person brings in all of
  their devices.
- An identifier shared by more than 50 devices is treated as **not set** (protects against a
  shared/guest identifier collapsing unrelated people into one).
- Windows are **UTC and day-aligned**: `"last_days": 7` starts at 00:00 UTC seven days ago.
- Counts are **exact**, not sampled. Built-in event and "any activity" conditions (with no
  filters) read a rollup that lags **up to about 10 minutes** for the current and two prior
  months, up to a day for older months, and always includes all of today — every other condition
  reads live data.
- `properties.<key>` always means the event's (or profile's) **own** property. A literal dotted
  key (`"user.plan"`) and the nested path `user` → `plan` are the same ClickHouse path, so either
  spelling matches.
- A "did not" condition (`negate`, `is_not`, `is_not_set`) is only valid in an `and` group that
  also has a positive condition. A "did not" whose window covers dates older than your data
  retention is refused (`422 window_expired`) — the deleted data could otherwise turn a real past
  purchaser into a false "did not purchase" match.
- A saved segment whose fixed-date window ages past your retention keeps working; responses carry
  `incomplete: true` instead of failing.
- Results are pinned for a page session: `count`, `users`, and `breakdown` share one materialized
  result (by `result_id`) for a few minutes. An expired cursor or `result_id` returns `410
  result_expired` — re-run `count` or reload to get a fresh one.
- Exports are downloaded through the dashboard via a 5-minute signed link; the completion e-mail
  carries no file link; export files are deleted 24 hours after creation.
- **Purchases count transactions.** A transaction counts once it has a `buy` row, unless it has
  been refunded without a later reversal — a refunded-and-not-restored purchase does not count.
  `quantity` sizes the spend total, it does not multiply the transaction count.
- `429 segment_busy` means "too many segment evaluations are running right now, retry in a few
  seconds" — it is a distinct signal from the `503` back-off used elsewhere in the API; it is safe
  to retry a `segment_busy` response after a short delay.

---

## Server API

Manage segments from your own server with the instance API key, the same credential as
`POST /api/v1/sdk/server/push`. Host `sdk.<your-domain>`, base `/api/v1/sdk/server`, headers
`PROJECT-KEY: <instance api key>` and `ENVIRONMENT: production|test` (the environment picks the
project, so paths carry no project id). Requests and responses are the dashboard's.

```bash
curl -X POST https://sdk.example.com/api/v1/sdk/server/segments \
  -H "PROJECT-KEY: $KEY" -H "ENVIRONMENT: production" -H "Content-Type: application/json" \
  -d '{ "name": "Buyers", "definition": { "version": 1, "operator": "or", "groups": [ ... ] } }'
```

| Call | Does |
|---|---|
| `GET /segments`, `GET /segments/fields` | List; the condition catalogue |
| `POST /segments/estimate` | Estimate a draft definition or a saved segment |
| `POST /segments`, `GET`/`PATCH`/`DELETE /segments/:segment_id` | Create, read, edit, archive |
| `POST /segments/:segment_id/count` | Exact count |
| `POST /segments/:segment_id/identifier_list` | Replace the identifier list (JSON `identifiers`) |

Members, breakdowns, exports, list preview/download and size history are dashboard-only and
answer `404` here. Estimates and counts run in their own permit pool, so server traffic never
queues behind the dashboard. Writes are audited as the API key; `created_by` stays empty.

Failures on top of the table below: `400` missing `PROJECT-KEY` or bad `ENVIRONMENT`, `403`
`Invalid credentials`, `403 enterprise_required` without an active paid plan (always on for self-hosted Enterprise), `429 rate_limited`
(JSON, with `Retry-After`) over 120 requests a minute per key.

---

## Errors

Every error is `{ "error": "…" }`; most segment-specific failures add `error_code`.

| Status | `error_code` | Meaning |
|---|---|---|
| `401` | — | Missing or invalid credential |
| `403` | — | Not a project member (or not an admin, on an admin-only action) |
| `404` | — | No such segment, or it belongs to another project, or it is archived |
| `409` | `upload_in_progress` | Another identifier upload for this segment is still running |
| `410` | `result_expired` | The pinned result behind a cursor, a first-page `result_id` on `users`, or a `breakdown` has expired or belongs to an older definition |
| `422` | `invalid_definition` | The definition cannot be evaluated: it no longer parses, uses `in_list` before a list was uploaded, or uses `purchase` without revenue collection |
| `422` | `window_expired` | A "did not" condition's window is older than your data retention |
| `422` | `query_too_heavy` | The query exceeded the memory/time budget — narrow a window or remove a condition |
| `422` | — | Plain validation failure (bad field/op/value); message names the condition path |
| `503` | `clickhouse_unavailable` | ClickHouse reads or writes are off or unreachable |
