# Changelog

All notable changes to the Grovs backend are documented here. Versions follow
[semantic versioning](https://semver.org/); the matching images are
`ghcr.io/grovs-io/backend:<version>` (Community Edition).

## [3.0.1] - 2026-10-28

### Fixed

- **Push notifications no longer get stuck for an hour when a connection to
  Apple or Google drops.** A reset connection made the push daemon lose track
  of the requests in flight, which then waited for the hourly stale release.
  Every push the provider never answered is now retried (after 1 s, then
  10 s), other errors are retried up to 8 times instead of failing at once,
  idle connections are reopened after 5 minutes, and a push that still fails
  gives up after a day instead of retrying forever. A silent connection can
  no longer hang the iOS sender. (Enterprise Edition)
- A retried push can reach a device twice if the provider accepted the first
  copy but its answer was lost. Each delivery now carries an APNs
  `apns-collapse-id` and an Android notification `tag`, so the device shows
  one notification.

### Security

- Development and deploy tooling: `net-ssh` 7.3.8 (via Kamal) and RuboCop 1.92,
  which no longer pulls in the `mcp` gem. No runtime dependency changed.

### Changed

- Push campaign `data` may no longer use the key `headers`: it is refused with
  `422` like `aps`, because it would be sent to Apple as request headers.

## [3.0.0] - 2026-10-26

### Upgrade notes

- **Back up first.** This release adds Postgres and ClickHouse migrations; the
  `migrate` step (or `db:prepare` on boot) applies them. The legacy notification
  tables are kept for one more release and dropped in a later one.
- **Custom events with reserved names are now rejected.** `push_open`,
  `push_delivered`, `push_held`, `in_app_*` and `journey_*` are recorded by the
  messaging features themselves; `POST /api/v1/sdk/event/custom` answers 400 for
  them and `events/batch` drops them per item. Rename any custom event that uses
  one of these names.
- **The legacy messages inbox is removed** (see Removed). Released SDKs keep
  working: the four inbox endpoints still answer 200 with empty results.
- New optional environment variables: `TRUSTED_PROXY_SECRET` (shared with the
  dashboard so auth requests carry the end user's IP), `CUSTOMER_GATEWAY_IPS`,
  `IN_APP_PREVIEW_ORIGINS`, `CLICKHOUSE_CA_CERT`, and the `RPUSH_*`, `SEGMENT_*`,
  `PUSH_DELIVERY_*` and `JOURNEY_*` tuning values. All have defaults.
- Enterprise Edition deployments need two more processes: a Sidekiq worker for
  `config/sidekiq_egress.yml` (event streaming, push, journeys, exports) and the
  push daemon `GROVS_ROLE=rpush bin/rpush-cluster`. The self-host compose runs
  both automatically when the image carries `ee/`.

### Added — Enterprise Edition (`ee/`)

- **Segments**: audiences from events, user attributes, devices and purchases,
  with live size estimates, members, breakdowns, size history and CSV exports.
- **Push campaigns** over APNs and FCM: targeting by segment, scheduling,
  delivery, holdout control groups, and open reporting.
- **In-app messages**: templates, star-rating and choice surveys, custom HTML
  with a shared JavaScript bridge, targeting, frequency caps, test messages and
  reports.
- **Journeys**: multi-step flows across push and in-app messages with waits,
  branches, A/B paths and conversion goals, including purchase and revenue goals.
- **Event streaming**: raw events delivered to S3-compatible storage or webhooks,
  or pulled from a feed with event stream tokens; exports of segments and events.
- Server-side APIs for segments and in-app messages, and MCP tools for analytics,
  segments and messaging reports.

### Added — core

- **Smart banners** for websites, linking visitors into the app.
- **Custom dashboards** and a unified analytics query API with filters,
  breakdowns and granularity.
- In-app browser handling: links opened inside social apps can show a page that
  sends the visitor to the real browser.
- Project icons from the App Store and Google Play in project lists.
- `sdk_status` for guided project setup, including when the web SDK was last seen.

### Changed

- Path lookups prefer the active link when a path was reused by an archived one,
  and archiving a campaign clears the cached lookups of its links.
- Enterprise scheduled jobs run only when `GROVS_EE=true` and `ee/app` exists, so
  a Community image never schedules jobs it does not contain.
- Deferred deep link claims are atomic.
- Proxy addresses of a customer's gateway (`CUSTOMER_GATEWAY_IPS`) are scrubbed
  like Cloudflare's when resolving the client IP.

### Removed

- The legacy notifications and marketing-messages feature, including the
  `/mm/*` message pages. Its SDK endpoints remain as stubs.

### Security

- `crass` 1.0.8 (CSS sanitizer bypass advisory).

## [2.3.1] and earlier

See the [GitHub releases](https://github.com/grovs-io/backend/releases).

[3.0.0]: https://github.com/grovs-io/backend/compare/2.3.1...3.0.0
[2.3.1] and earlier: https://github.com/grovs-io/backend/releases
