# Grovs Journeys API

A **journey** moves each person through a map of steps: wait, split, send a push, show an in-app message, set an attribute.
People enter on an event or by joining a segment, and leave when the path ends, when they reach a goal, or after 90 days.

- **Base URL:** `https://api.<your-domain>/api/v1/projects/:project_id/` (numeric project id)
- **Auth:** `Authorization: Bearer <token>`; any member of the instance reads, drafts, edits, launches, pauses,
  resumes and ends.
- **Availability:** where in-app messages are available; `404 "Journeys are not enabled"` otherwise. `JOURNEYS_ENABLED=false`
  stops the engine (nobody enters or moves); the API stays readable.

## Endpoints

| Method | Path | Notes |
|---|---|---|
| `GET` | `journeys?status=&after=&limit=` | Newest first; keyset `after` (last `id`), `limit` ≤ 200. `{ journeys, truncated, next_after }`; rows omit `steps` and carry `stats: { active, entered }` (the single-journey responses do not; use the report) |
| `POST` | `journeys` | Create a draft. `201 { journey }` |
| `GET` | `journeys/:journey_id` | `{ journey }` |
| `PATCH` | `journeys/:journey_id` | Draft: any field. Live or paused: only the name and step content (push text, link, image, data, sound, quiet hours; in-app content, triggers, caps, `valid_days`; attribute value), wait `minutes` and split percentages; anything else is `422 "The steps, entry and goals cannot change after launch"`. `lock_version` optional: `409` when stale. Ended: `409` |
| `DELETE` | `journeys/:journey_id` | Draft only, else `409` |
| `POST` | `journeys/:journey_id/launch` | Draft → live (entry opens at `start_at` when it is in the future). `422` with up to three problems joined by `; ` |
| `POST` | `journeys/:journey_id/pause` · `/resume` · `/end` | live ↔ paused, → ended; `409` from the wrong state |
| `POST` | `journeys/:journey_id/duplicate` | `201`, a draft copy named "… copy" |
| `POST` | `journeys/:journey_id/images` | Multipart `image`: PNG/JPEG/GIF (≤ 1 MB), MP4 (≤ 20 MB), or MP3/M4A (≤ 10 MB), read from the bytes — the same types and caps as an in-app campaign's media. At most 30 files and 100 MB per journey, counting every file it holds; each upload first deletes files no step references that are over a day old. Optional `lock_version` (`409` when stale, as for PATCH). `201 { url, lock_version }` (an upload saves the journey, so send that `lock_version` with the next edit), the permanent address to put in a push step's `image_url` or an in-app step's `content.image` or `content.html`. `422` for another type, a larger file, or over a cap; an ended journey takes none (`409`). Files stay with the journey and go when it is deleted; `duplicate` carries over only those a step still references (its `html` included) and rewrites their addresses |
| `GET` | `journeys/:journey_id/report?from=&to=` | See Report; `422` for a bad range (at most 92 days), `503 clickhouse_unavailable` |

## The journey

```json
{ "id": "hashid", "name": "Cart recovery", "status": "draft|live|paused|ended", "revision": 1, "lock_version": 0,
  "entry": { "type": "event", "event": { "name": "add_to_cart", "screen": null, "filters": [ { "field": "value", "op": "gt", "value": 20 } ] },
             "segment_id": null, "audience_segment_id": null },
  "re_entry": { "mode": "once|after_exit|after_days", "days": null },
  "goals": [ { "event": "checkout_completed", "window_hours": 168 } ],
  "control_group": 10, "start_at": null, "end_at": null,
  "first_step": "s1", "steps": { "s1": { "id": "s1", "type": "wait", "minutes": 60, "until": null, "next": "s2", "timeout_next": null } },
  "launched_at": null, "ended_at": null, "created_at": "…", "updated_at": "…" }
```

- **Event specs** (`entry.event`, a wait's `until.event`, a split's `condition.event`, goals) name exactly one of `name` (custom event),
  `screen` (matched in any case), or `system`: `install`, `reinstall`, `app_open`, `open` (link opened), `view` (link viewed) or `reactivation`. Custom events and screens take up to 5 filters in the in-app trigger filter format; a system event
  takes none (`422 "cannot filter a system event"`). An install arrives before the app identifies the person, so they enter as the
  device and stay in the journey when they identify.
- `entry.type` `event`: `event` is an event spec. `segment`: `segment_id` required; people who join the segment enter, checked every 15 minutes.
  Entry events more than an hour old are ignored.
- `audience_segment_id`: only people in that segment may enter. Every segment a journey uses counts toward the project's 20 tracked segments.
- `re_entry`: `once`; `after_exit` (again once they left); `after_days` (again `days` after they left, 1 to 365). Nobody is in a journey twice at once.
- `goals`: up to three `{ event|screen|system, window_hours }` or `{ purchase: true, products?, window_hours }`. Reaching one takes the person out from any step. A purchase goal is met by a store purchase after entry (of a listed product, when `products` is given). `window_hours` does not limit the exit; the report counts reaching any goal as a conversion, as the exit does, within the first goal's window, which also sets the revenue window (the dashboard sends 168).
- `control_group`: null or 1 to 50 percent held back. The project-wide control group (in-app settings) holds people from journeys too.
- Pause stops entries and moves and holds the journey's queued pushes and in-app messages; resume releases them and lets in
  entry-segment members who joined meanwhile (as does the start time for a segment entry).
- **Data kept** (one row per person per journey): `once` keeps it while the journey runs; `after_exit` on an event entry keeps a leaver's row
  a day (only an event after they left lets them back, so a retried or late event cannot); `after_days` drops it N days after they left; every row goes once an ended journey has finished. Counts and
  reports are kept separately and never change.
- `end_at`: nobody enters after it; people inside finish. An ended journey's channels stay up until nobody is left.

## Steps

Every step has `id` (`^[a-z0-9_]{1,16}$`), `type` and its next pointers; `null` ends the path. Pointers must name steps, paths may
join, loops are refused, at most 60 steps.

| Type | Fields | Branches |
|---|---|---|
| `wait` | `minutes` 5 to 43200; `until` null, `{ kind: "event", event }`, `{ kind: "opened", step: <push step above> }` or `{ kind: "clicked", step: <in-app step above> }` | `next`; with `until`: `next` (did it) and `timeout_next` (time ran out) |
| `split` | `mode: "condition"` with `condition`, or `mode: "percent"` with 2 or 3 `paths` `{ percent, next }` adding up to 100 | `yes_next` / `no_next`, or `path_0`… |
| `push` | `title`, `body`, `link_id`, `image_url`, `data`, `sound`, `quiet_hours`; `campaign_id` read-only | `next` |
| `in_app` | `template`, `content`, `triggers`, `caps` as an in-app campaign; `valid_days` 1 to 30; `campaign_id` read-only | `next` (once viewed, or when it expires) |
| `set_attribute` | `key` `^journey_[a-z0-9_]{1,40}$`, `value` text up to 255 | `next` |

Conditions: `{ kind: "event", event, days: 1..90, min_count }` (ClickHouse), `{ kind: "segment", segment_id }`,
`{ kind: "attribute", key, op: eq|neq|contains|exists|not_exists|gt|lt, value }`, `{ kind: "platform", values: [ios, android, web] }`.
A percent split is fixed per person: the same person always takes the same path. After launch a path may be set to 0 (the others still adding up to 100) to send everyone who reaches the split down the rest, such as the winning path; people already past it stay where they are.

- A push step owns a push campaign (`source: "journey"`, hidden from the push list; its report works as usual). With `quiet_hours`
  the push goes out between 09:00 and 21:00 on the device's clock, else at the next 09:00 there; a wait right after it counts from then. The project's daily push cap applies.
- An in-app step owns an in-app campaign (hidden from the in-app list; edit it through the journey). The person's device gets it at its
  next sync and shows it on its own trigger with the usual caps. `template` may be `html`, checked the same as a campaign's own
  content (see `in-app-messaging-api.md`).
- `set_attribute` writes the key on every device of the person; the SDK's own attribute updates keep `journey_` keys.
- Split, push and set attribute run at once, up to 20 in a row; a wait moves on within a minute of its time.

## Report

```json
{ "report": {
  "entered": 5310, "held": 590, "active": 1204,
  "left": { "finished": 3200, "goal": 700, "expired": 206 },
  "steps": { "s1": { "reached": 5310, "now": 820, "branches": { "next": 3010, "timeout_next": 1480 } } },
  "goal": { "goal": { "event": "checkout", "window_hours": 168 }, "groups": [ … ], "lift": 0.12, "confidence": 0.97, … },
  "paths": { "s3": { "goal": { "purchase": true, "window_hours": 168 }, "control_group": 0, "groups": [ { "id": "a", … }, { "id": "b", … } ], … } } } }
```

Counts are per day in `from..to` (UTC; `from` defaults to the launch day); `active` and `now` are live. `goal` is the experiments
report for the first goal, exposure `journey_entered`, control `journey_held`, group `a` = in the journey.
`expired` counts people taken out after 90 days. `active` and `now` are refreshed at most once a minute. The card is there when the
journey has a goal or a control group; it carries the same revenue fields.

`paths` has one experiments report per percentage split, keyed by step id (`{}` when there is none). Groups `a`, `b`, `c` are
paths 1–3, read from the `journey_path` event the step records, so later percentage edits report correctly; each path's
`confidence` is against path A, and there is no control. Only people who reached the split count, with the first goal and its
window as on the goal card. Journeys run before 2026-10-02 recorded no paths, so their reports have none.
