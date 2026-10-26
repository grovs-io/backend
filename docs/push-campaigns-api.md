# Grovs Push Campaigns API

Send a **push notification** to a segment, to a list of your users, or to a list of devices — from
the dashboard or from your server — and see what happened to it: targeted, no channel, handed to
APNs / FCM, delivered, failed by error, opened.

- **Base URL:** `https://api.<your-domain>/api/v1` (dashboard) · `https://sdk.<your-domain>/api/v1` (server API)
- **Dashboard auth:** `Authorization: Bearer <token>`; any member of the project's instance
- **Server auth:** `PROJECT-KEY` + `ENVIRONMENT` headers (enterprise plans and the self-hosted enterprise image)
- **Availability:** every plan on Grovs Cloud, and the self-hosted enterprise image (absent from the
  open-source image). Segment audiences need ClickHouse. The `rpush` process must be running
  (self-hosted: the `rpush` service).

Use the numeric project ID in dashboard paths (`123` below). Campaign ids and segment ids are
hashids; `link_id` is the numeric link id the links API returns; visitors are addressed by their `uuid` (the `uuid` field of every visitor object the
API returns); users by the `sdk_identifier` your app set.

---

## Contents

- [Quickstart](#quickstart)
- [The campaign object](#the-campaign-object)
- [Audiences](#audiences)
- [Scheduling and local time](#scheduling-and-local-time)
- [Lifecycle](#lifecycle)
- [Delivery report](#delivery-report)
- [Dashboard endpoints](#dashboard-endpoints)
- [Server-to-server API](#server-to-server-api)
- [Push payload and SDK contract](#push-payload-and-sdk-contract)
- [Errors](#errors)

---

## Quickstart

### 1. Create a draft

```bash
curl -X POST https://api.example.com/api/v1/projects/123/push_campaigns \
  -H "Authorization: Bearer $DASHBOARD_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "name": "Spring launch",
    "title": "Spring is here",
    "body": "Open the app for 20% off this week",
    "image_url": "https://cdn.example.com/spring.png",
    "sound": "default",
    "link_id": 4821,
    "data": { "promo": "spring26" },
    "audience": { "type": "segment", "segment_id": "s9Kq1" }
  }'
```

`201` → `{ "push_campaign": { "id": "k9Qx2", "status": "draft", … } }`

Other audiences:

```json
"audience": { "type": "identifiers", "recipients": ["user_1", "user_2"] }
"audience": { "type": "visitors", "recipients": ["550e8400-e29b-41d4-a716-446655440001"] }
```

### 2. Check the reach

```
POST …/push_campaigns/k9Qx2/estimate    (only iOS has a configured APNs app for this project)
{ "devices": 41230, "no_channel": 1180, "not_found": 0, "no_app": 16230, "reachable": 23820,
  "platforms": { "ios": { "devices": 23820, "configured": true }, "android": { "devices": 16230, "configured": false } } }
```
`devices`, `no_channel`, `not_found` (and, for segment audiences, `persons`/`incomplete`) are unchanged.
`no_app` counts devices on a push platform (iOS/Android) with no configured APNs/FCM app for this
project; `reachable` is what would actually get delivered to. `platforms` breaks the with-channel
population down per platform. **List audiences** (`visitors`/`identifiers`): token presence is known,
so `reachable + no_app == devices - no_channel`, and `platforms.ios.devices + platforms.android.devices`
equals that same with-channel count. **Segment audiences:** push-token presence isn't known in
ClickHouse, so `platforms[*].devices`/`reachable`/`no_app` there mean "on a configured push platform,
active within the last 30 days" only, and are **approximate** (not the exact `devices`/`persons`
counts) — `ios + android` can be **less than** `devices`, since a device on web/desktop, or one
ClickHouse hasn't seen a profile for in the last 30 days, is counted in `devices` but in neither
platform bucket; and a device counted as reachable may still turn out to have no token once delivered
to. For a very broad segment audience the split can be too expensive to compute at all: when that
happens, `no_app`, `reachable` and both `platforms[*].devices` come back **`null`** — `devices`,
`persons` and every other field are unaffected, and the request still succeeds (no error).

### 3. Send now, or schedule

```bash
curl -X POST https://api.example.com/api/v1/projects/123/push_campaigns/k9Qx2/send \
  -H "Authorization: Bearer $DASHBOARD_TOKEN" -H "Content-Type: application/json" \
  -d '{ "scheduled_at": "2026-10-01T09:00:00Z", "local_time": true, "timezone": "Europe/Bucharest" }'
```

`202` → the campaign with `status: "scheduled"` (or `"evaluating"` when sent immediately). Poll
`GET …/push_campaigns/k9Qx2` for the report.

---

## The campaign object

| Field | Type | Notes |
|---|---|---|
| `id` | string | hashid |
| `name` | string | Internal label, max 255 chars |
| `title`, `body` | string | `title` max 255 chars, `body` max 1000 chars. The whole APNs payload must fit in 4096 bytes — long bodies with a long `image_url` or `data` are refused with `422` |
| `image_url` | string \| null | `https://` only. Use a PNG, JPEG or GIF: iOS shows no other format. iOS needs a Notification Service Extension in your app to render it; Android renders it natively |
| `image` | string \| null | Read-only: the URL the push will carry — `image_url` when set, else the uploaded file. Upload by sending a multipart `image` file (PNG, JPEG or GIF, max 1 MB — Firebase will not load more, and iOS extensions time out on slow links) on `POST` or `PATCH`; no resizing is done, around 1038×1038 is the sweet spot; `DELETE …/image` removes it. The server API takes `image_url` only |
| `sound` | string \| null | `default` or a sound file bundled in your app (max 64 chars); Android needs a notification channel with that sound |
| `link_id` | integer \| null | A Grovs link of this project (numeric id); its URL travels in the payload as `grovs_link` |
| `data` | object | Custom key/values delivered in the push payload, max 2 KB serialised. `grovs_campaign_id`, `grovs_link` and `grovs_image` are reserved and overwritten. `aps`, `from`, `notification`, `message_type` and keys starting with `google`, `gcm` or `__rpush_` are refused with `422`: they would break the APNs or FCM payload |
| `source` | string | `dashboard` or `api`. Campaigns a journey owns (`journey`, status `live`) are left out of the list; see `journeys-api.md` |
| `status` | string | See Lifecycle |
| `audience` | object | `{ type, recipients_count, segment_id, segment_definition_hash }`, plus `recipients` on single-campaign responses (the list omits it) |
| `scheduled_at`, `local_time`, `timezone` | | See Scheduling |
| `report` | object | See Delivery report |
| `control_group` | integer \| null | 1 to 50: the percent of the audience kept from the push, as a control. See Experiments |
| `conversion` | object \| null | `{ "event": "checkout", "window_hours": 24 \| 72 \| 168 }` or `{ "screen": "Checkout", "window_hours": … }` or `{ "system": "reactivation", "window_hours": … }` (one of `install`, `reinstall`, `app_open`, `open` (link opened), `view` (link viewed) or `reactivation`) or `{ "purchase": true, "products": ["premium_month"], "window_hours": 24 \| 72 \| 168 \| 720 }`: a custom event, a screen view of that screen, that system event, or a store purchase (`buy`, renewals included; of one of `products` when given, 1 to 20 product ids) counts as a conversion when it follows delivery within the window. `products` is refused on other goals and 720 hours only applies to purchase goals. Message events are refused |
| `variants` | array \| null | Up to two `{ "id": "b" \| "c", "title", "body" }`; the campaign's own title and body are variant `a`. Each variant's payload must fit APNs too |
| `test_share` | integer \| null | 10 to 50, with variants only: the percent of the audience that receives the variants at once; the rest waits for `send_winner`. Not with `local_time`. People still waiting when the delivery rows are purged (30 days after the send) are let go: `waiting` drops to 0 and nothing more is sent |
| `winner_after_minutes`, `winner_by` | integer \| null, string \| null | With a test share: send the winner by itself after 30, 60, 120, 360, 720 or 1440 minutes, judged by `opens` (default) or `conversions` (needs a goal). The best rate wins once every variant has reached at least 100 people; ties, and fewer people, go to A. Null: you press "send the winner" yourself |
| `winner_due_at`, `winner` | read-only | When the timer fires (null once it has, or without a timer); the variant sent to the rest, by hand or by the timer |
| `evaluated_at`, `started_at`, `finished_at`, `failure_reason` | | Timestamps and outcome |

## Audiences

| `audience.type` | Targets | Resolves to |
|---|---|---|
| `segment` | `segment_id` of an active segment of the project | Every device of every person in the segment, **evaluated when the campaign is sent** (or released, when scheduled). The segment's definition is snapshotted at send time: editing the segment afterwards never changes the audience |
| `identifiers` | your own user ids (`sdk_identifier` exactly as your app sent it), up to 10,000 | Every device of that user, at most 50 per identifier |
| `visitors` | visitor `uuid`s, up to 10,000 | That device |

Each recipient is a non-empty string of at most 256 bytes. Unknown recipients (including malformed
uuids) are counted in `report.not_found`. Devices with no push token, or on web / desktop, are
counted in `report.no_channel` and skipped. `report.targeted` counts every resolved device.

The audience is **frozen** when it is evaluated: a user identified afterwards is not reached.

## Scheduling and local time

- `POST …/send` without a body sends now.
- `scheduled_at` (ISO 8601) must be in the future and at most 30 days away. The campaign becomes
  `scheduled` and is released by a minute tick; it can be cancelled until then.
- `local_time: true` delivers at `scheduled_at`'s **wall-clock time in each device's own timezone**
  (as last reported by the device). `timezone` (IANA name, default `UTC`) says which zone the
  wall-clock is read in and is the fallback for devices without a timezone. A local-time campaign
  is evaluated when the nominal time is first reached anywhere (UTC+14), i.e. 14 hours minus the
  `timezone`'s UTC offset before `scheduled_at` (21 hours for UTC-7, 5 hours for UTC+9), and must be
  scheduled at least that far ahead; a slot already past for a device goes out immediately.
  Delivery of one campaign therefore spans about 26 hours.

## Lifecycle

```
draft ──send──▶ scheduled ──tick──▶ evaluating ──▶ sending ──▶ sent
  │                 │                   │             │
  │                 │                   └──▶ failed   └──cancel──▶ cancelled
  └──cancel──▶ cancelled ◀──cancel──┘
```

- A draft can be edited (`PATCH`) and cancelled. A scheduled campaign can be cancelled.
- Once sent, a campaign is never re-sent; duplicate it instead. A refused re-send (`409`) never
  touches the segment snapshot.
- **Cancel while sending** drops every device not yet handed to APNs / FCM (`report.cancelled`),
  including pushes already queued in the push process but not yet picked up; the batches it is
  sending at that moment (at most about 1,000 devices per platform) still go out. Cancel is refused
  (`409`) during the seconds of `evaluating`.
- Delivery is at-least-once: if the push process dies right after APNs / FCM accepted a push, that
  push is sent again when it restarts.
- Delivery runs at the push process's pace (about 2,000 pushes/s per `rpush` process at the default
  settings, measured against a 100 ms provider): a campaign of 1M devices takes about 8–10 minutes. It becomes `sent` once every device has been
  handed off, normally a few seconds before the last pushes reach APNs / FCM; pushes the provider
  asked to retry later keep going out after that.
- `failed` reasons: `segment_busy` (the segment could not be evaluated in ten attempts spread over about three hours),
  `segment_invalid` (definition no longer parses, window expired, or the segment was archived),
  `query_too_heavy`, `evaluation_error`.

## Delivery report

```json
"report": {
  "targeted": 41230, "no_channel": 1204, "not_found": 0, "cancelled": 0,
  "queued": 40026, "delivered": 39511, "failed": 515, "opened": 2210, "held": 4120, "waiting": 0,
  "error_counts": { "Unregistered": 480, "404": 35 },
  "audience": { "persons": 38120, "devices": 41230, "incomplete": false }
}
```

- `queued` = handed to the push process, which is kept at most a few seconds ahead of APNs / FCM.
  `delivered` = accepted by APNs / FCM (not "shown on screen").
  `failed` = rejected, by reason: APNs reasons keep their name (`Unregistered`, `BadDeviceToken`,
  `PayloadTooLarge`, …); FCM failures are keyed by HTTP status (`404` = not registered). APNs
  `429`/`500`/`503` are retried every 10 seconds until accepted; FCM `5xx` are retried with backoff,
  and FCM `429` too until the push has had 8 retries of any kind.
- `app_removed` = the APNs / FCM credentials were replaced or removed while the push waited to go out.
- A device rejected as `Unregistered` / `BadDeviceToken` / FCM `404` loses its push token, so the
  next campaign counts it in `no_channel` instead of failing again.
- `opened` counts devices whose SDK reported a tap (once per device per campaign); it is also
  logged as the analytics event `push_open` with the campaign id, so it shows in the explorer.
- `held` counts people kept back as a control (the campaign's own or the project-wide one); they are not in `targeted`. `waiting` counts people outside the test share, still to receive the winner.
- `audience.incomplete` is `true` when a segment window reached past your data retention.
- Per-device rows (`GET …/deliveries`) are kept for 30 days; the counters stay forever. A journey's campaigns never finish, so their rows go 30 days after they were created.
- **Daily cap.** `push_daily_cap` in the in-app settings (`PATCH /in_app_settings`, 1 to 50, `null` = off) limits how many pushes one person
  gets per UTC day, across every campaign and journey of the project. A push over the cap is not sent: it counts in `failed` under the
  error `capped`. The count is kept per device's visitor, so a person on two phones has two counters.

## Dashboard endpoints

All under `/api/v1/projects/:project_id/`. Admin only.

| Method | Path | Notes |
|---|---|---|
| `GET` | `push_campaigns?status=&after=&limit=` | Newest first (by creation); keyset on `after` (the last row's `id`), `limit` ≤ 200 (default 200); `next_after` is `null` on the last page and `truncated` says more exist; slim rows (`recipients_count`, no `recipients`) |
| `POST` | `push_campaigns` | Body: the fields above plus `audience`; `201` |
| `GET` | `push_campaigns/:id` | Campaign with `report` and `audience.recipients` |
| `PATCH` | `push_campaigns/:id` | Same fields as create; `409` unless `draft` |
| `POST` | `push_campaigns/:id/send` | `{ scheduled_at?, local_time?, timezone? }`; `202`; `409` unless `draft`; `422` for a bad schedule |
| `POST` | `push_campaigns/:id/cancel` | From `draft`, `scheduled` or `sending`, or `sent` with people waiting; `409` otherwise |
| `POST` | `push_campaigns/:id/send_winner` | `{ variant }`: sends that variant to everyone kept waiting by `test_share`; `202`, once; `409` otherwise. The response sets `winner` while the campaign is still `sent`; a background job moves it to `sending` within seconds |
| `GET` | `push_campaigns/:id/experiment?from=&to=` | The groups of an experiment, see Experiments; `422` for a campaign with none |
| `DELETE` | `push_campaigns/:id/image` | Removes the uploaded image; `409` unless `draft` |
| `POST` | `push_campaigns/:id/estimate` | `{ devices, no_channel, not_found, no_app, reachable, platforms }` (+ `persons`, `incomplete` for segments; see "Check the reach"), no side effects; segment errors come back as `422 invalid_segment` / `query_too_heavy`, `429 segment_busy`, `503 clickhouse_unavailable` |
| `POST` | `push_campaigns/estimate` | Same response shape as above, for a draft: body is `{ audience }`; any other fields are ignored and nothing is saved; invalid audience (empty/oversized `recipients`, missing or archived `segment_id`) is `422` with the same messages `create` gives |
| `GET` | `push_campaigns/:id/deliveries?status=&after=&limit=` | One row per device: `{ id, status, platform, recipient, error, opened_at, visitor }`; keyset on `after` (last `id`), `limit` ≤ 200, `next_after` is `null` on the last page |

Delivery `status` values: `pending`, `claimed`, `queued`, `delivered`, `failed`, `no_channel`,
`not_found`, `cancelled`, `held`, `waiting`.

## Experiments

Each person has a fixed bucket per campaign (`MD5("<campaign id>:<visitor id>")`, first 4 bytes, mod 100), computed when the audience is frozen: the first `control_group` percent are held, the rest split evenly between the variants. A second bucket, over the project id, holds the project-wide control group set in the in-app settings (`control_group`), who receive no push and no in-app message at all. A third, over `"<campaign id>:test"`, keeps everyone above `test_share` waiting. People without a push channel are counted as `no_channel`, never held.

Exposure is written to ClickHouse as events with the campaign id: `push_delivered` (with `variant`) for everyone handed a variant, written at the freeze like `push_held` (intent to treat: a failed or undelivered push still counts; the waiting share is written when the winner is sent; the conversion window therefore starts at the freeze for both arms, so a `local_time` send due hours later with a short `window_hours` undercounts both), for a campaign with an experiment or in a project with a control group, `push_held` (with `scope` `campaign` or `project`) for the held. `push_open` already exists. The report joins them with the goal event:

```json
{ "goal": { "event": "checkout", "window_hours": 24 }, "control_group": 10, "project_control_group": 0, "test_share": 20,
  "groups": [
    { "id": "a", "exposed": 4120, "clicked": 610, "click_rate": 0.148, "converted": 233, "conversion_rate": 0.0566, "confidence": null,
      "revenue_cents": 412000, "revenue_per_person_cents": 100 },
    { "id": "b", "exposed": 4098, "clicked": 702, "click_rate": 0.1713, "converted": 268, "conversion_rate": 0.0654, "confidence": 0.96,
      "revenue_cents": 409800, "revenue_per_person_cents": 100 },
    { "id": "control", "exposed": 910, "clicked": null, "click_rate": null, "converted": 31, "conversion_rate": 0.0341, "confidence": null,
      "revenue_cents": 77350, "revenue_per_person_cents": 85 } ],
  "lift": 0.83, "added_conversions": 47, "confidence": 0.99, "more_people_needed": null,
  "revenue_lift": 0.18, "added_revenue_cents": 123300 }
```

`exposed` counts people delivered to (or held) in the range, `clicked` those who opened, `converted` those who raised the goal event within the window after delivery. A variant's `confidence` is a one-sided two-proportion z-test against `a` (on conversion rate, or open rate without a goal), null under 100 people a side. `lift`, `added_conversions`, `confidence` and `more_people_needed` compare all variants together with the campaign's control; null without a control or a goal. `from` defaults to the day the campaign started, at most 92 days back; the range may be at most 92 days. Cached for 60 seconds. The project-wide control group holds people from dashboard campaigns only; pushes sent through the server API are not held. `revenue_cents` is net USD cents (refunds subtracted, as the revenue ledger) of store purchases within the goal's window after exposure, 72 hours without a goal; `revenue_per_person_cents` divides it by `exposed`. `revenue_lift` and `added_revenue_cents` compare all variants with the campaign's control from unrounded figures; null without a control or with nobody on a side, and `revenue_lift` also when the control's revenue is zero or less. A visitor merge leaves earlier purchases under the old visitor.

To let a campaign wizard pick a `link_id`, `GET /api/v1/projects/:project_id/links/lookup?term=&limit=`
(any project member, not admin-only) returns `{ links: [...] }` — active, non-SDK-generated links
matching `term` (name/title/subtitle/path, case-insensitive), most recently created first, `limit` capped at
50 (default 20). Unlike `links/search_v2`, it has no retention window, so it can find links of any age.

## Server-to-server API

Enterprise plans (and the self-hosted enterprise image). Headers: `PROJECT-KEY: <instance api key>`,
`ENVIRONMENT: production|test`. Host: `sdk.<your-domain>`.

```bash
curl -X POST https://sdk.example.com/api/v1/sdk/server/push \
  -H "PROJECT-KEY: $KEY" -H "ENVIRONMENT: production" -H "Content-Type: application/json" \
  -d '{ "title": "Your order shipped", "body": "Tap to track it", "link_id": 4821,
        "audience": { "type": "identifiers", "recipients": ["user_1"] } }'
```

`202` → `{ "campaign": { … } }`, the same object as the dashboard returns; `name` defaults to the
title. `GET /api/v1/sdk/server/push/:id` → `{ "campaign": { … } }` with the live report.

- The response is `202` with `status: "evaluating"`; the audience is resolved and handed to the
  push process by a background job within a couple of seconds. Poll the report for progress.
  `scheduled_at`, `local_time` and `timezone` work as above.
- Limits, per project and per minute: **600 campaigns**, **10 segment campaigns**, **100,000
  recipients** — all answered `429 { "error", "error_code": "rate_limited" }`. A refused request
  creates nothing and charges no budget.
- Responses: `403 enterprise_required` on a non-enterprise plan; `404` when push campaigns are
  not available; `422 { "error" }` on validation failures, including `Link not found`,
  `Segment not found` and `data must be an object`.

## Push payload and SDK contract

Every push carries, next to your own `data` keys: `grovs_campaign_id` (hashid), `grovs_link` (the
link URL, when set) and `grovs_image` (when set). APNs pushes with an image set `mutable-content`.

On tap the Grovs SDK must call `POST /api/v1/sdk/push_open` (device auth) with
`{ "campaign_id": "<grovs_campaign_id>", "session_id": "…" }` — that is what fills `opened` — and
resolve `grovs_link` through the normal deep-link callback, sending `"source": "push"` to
`POST /api/v1/sdk/data_for_device_and_url`. With it the server returns the link's data without counting
a link open or matching devices, and the SDK does not attribute later events to the link: a tap is
counted once, as `push_open`. `push_open` is a reserved event name; the generic custom-event endpoint
refuses it.

## Errors

Every error is `{ "error": "…" }`; the server API adds `error_code` on `403` and `429`.

| Status | Meaning |
|---|---|
| `401` | Missing or invalid credential |
| `403` | Not a member of the project's instance; server API: not an enterprise plan |
| `404` | No such campaign, or it belongs to another project, or push campaigns are not enabled |
| `409` | Wrong status for the action, or the campaign changed while you were editing it (reload and retry) |
| `422` | Validation failure: message names the field; also `Link not found`, `Segment not found`, payload over 4096 bytes, a past / too-far / too-close schedule, unknown timezone, non-object `data` or `audience` |
| `429` | Server API budget exceeded (`rate_limited`); segment estimate with no permit free (`segment_busy`) |
| `503` | ClickHouse unavailable for a segment estimate (`clickhouse_unavailable`) |
