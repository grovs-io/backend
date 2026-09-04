<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://s3.eu-north-1.amazonaws.com/grovs.io/full-white.svg">
    <img src="https://s3.eu-north-1.amazonaws.com/grovs.io/full-black.svg" width="120" alt="Grovs">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/grovs-io/backend/releases"><img src="https://img.shields.io/github/v/release/grovs-io/backend?style=flat-square&color=4F46E5" alt="Latest release"/></a>
  <a href="#"><img src="https://img.shields.io/badge/Rails-8.1-4F46E5?style=flat-square&logo=rubyonrails&logoColor=white" alt="Rails 8.1"/></a>
  <a href="#"><img src="https://img.shields.io/badge/Ruby-3.4-4F46E5?style=flat-square&logo=ruby&logoColor=white" alt="Ruby 3.4"/></a>
  <a href="#"><img src="https://img.shields.io/badge/PostgreSQL-16-4F46E5?style=flat-square&logo=postgresql&logoColor=white" alt="PostgreSQL 16"/></a>
  <a href="#"><img src="https://img.shields.io/badge/deploy-Kamal-4F46E5?style=flat-square" alt="Deploy with Kamal"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT%20%2B%20EE-4F46E5?style=flat-square" alt="MIT + Enterprise License"/></a>
  <a href="https://github.com/grovs-io/backend/stargazers"><img src="https://img.shields.io/github/stars/grovs-io/backend?style=flat-square&color=4F46E5" alt="GitHub stars"/></a>
</p>

<p align="center">
  Self-hostable deep linking, attribution, and analytics platform for mobile apps.
  <br />
  An open-source alternative to Branch.io and AppsFlyer.
</p>

<p align="center">
  <a href="https://grovs.io">Website</a> &middot;
  <a href="https://docs.grovs.io">Documentation</a> &middot;
  <a href="https://github.com/grovs-io/backend/issues">Issues</a>
</p>

---

## What is Grovs?

Grovs gives you full control over your mobile app's growth stack:

- **Deep Linking** — Short links with deferred deep linking across iOS, Android, and web, including clipboard-assisted matching
- **Attribution** — Track installs, opens, reinstalls, and referrals back to their source
- **Revenue Tracking** — In-app purchase tracking with Apple/Google webhook integration and revenue attribution
- **Analytics** — Real-time dashboards with daily metrics, visitor stats, campaign performance, sessions and retention, optionally backed by ClickHouse
- **Custom Domains** — Serve links from your own domain via Cloudflare for SaaS, or with a manual DNS setup when self-hosting
- **Migration** — Move existing Branch.io or AppsFlyer links over; the first click on an old link resolves it upstream and mints a native Grovs link
- **Push Notifications** — Send targeted messages to your users via APNs and FCM
- **Multi-tenant** — One instance serves multiple apps across platforms
- **Enterprise** — Tamper-evident audit log with SIEM export, and enterprise SSO (OIDC) with SCIM 2.0 user provisioning (see [Enterprise Edition](#enterprise-edition))

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Framework | Ruby on Rails 8.1 / Ruby 3.4 |
| Database | PostgreSQL 16 |
| Analytics store | ClickHouse 25.3+ (optional, off by default) |
| Cache & Queues | Redis 6 |
| Background Jobs | Sidekiq with sidekiq-scheduler |
| Authentication | Devise + Doorkeeper (OAuth2) + OmniAuth (Google, Microsoft) + OIDC/SCIM (EE) |
| File Storage | S3 or any S3-compatible store via ActiveStorage |
| Payments | Stripe (billing), App Store Server API + Google Play Developer API (IAP) |
| Push Notifications | RPush (APNs + FCM) |
| Deployment | Docker / Kamal / docker-compose |

## Architecture

```
React Dashboard ──→ Doorkeeper OAuth2 ──→ Rails API ──→ PostgreSQL
                                             │
Mobile SDKs (iOS/Android) ──→ SDK API ───────┤
                                             │
Apple/Google Webhooks ──→ Webhook API ───────┤
                                             │
                                         Sidekiq Workers ──→ Redis
                                             │
                                         ClickHouse (optional analytics store)
```

The app is multi-tenant: **Instance** is the top-level tenant, each instance has a **test** and **production** Project. Users belong to instances via **InstanceRole**. Domains are attached to projects and resolve short links.

Events arrive from the SDKs and link clicks, are queued in Redis, and are processed in batches into daily statistics. With ClickHouse enabled the same events are also written there and the analytics dashboards read from ClickHouse rollups.

### API Routing (subdomain-based)

| Subdomain | Purpose | Auth |
|-----------|---------|------|
| `api.*` | Dashboard API (CRUD, analytics, config) | Doorkeeper OAuth2 |
| `sdk.*` | Mobile SDK (events, links, purchases) | Device fingerprint |
| `go.*` | Short link redirects | None |
| `preview.*` | Link previews | None |
| `mcp.*` | MCP server for AI tools | OAuth 2.1 |
| `<project>.<domain>` | Project deep links (built-in and custom domains) | None |

`SERVER_HOST` must be the bare domain (for example `links.example.com`), not the `api.` host. The reserved subdomains derive from it. Nested domains with three or more labels are supported.

## Quick Start

### Docker Compose (recommended)

No source checkout needed: the stack runs the published Community Edition image.

```bash
# 1. Fetch the compose file and the env template
mkdir grovs && cd grovs
curl -fsSLO https://github.com/grovs-io/backend/releases/latest/download/docker-compose.yml
curl -fsSL  https://github.com/grovs-io/backend/releases/latest/download/.env.example -o .env

# 2. Generate the secrets and put them in .env
docker compose run --rm --no-deps web bin/rails secret                # SECRET_KEY_BASE
docker compose run --rm --no-deps web bin/rails db:encryption:init    # the 3 ACTIVE_RECORD_ENCRYPTION_* keys
# Also set BOOTSTRAP_ADMIN_EMAIL / BOOTSTRAP_ADMIN_PASSWORD for your first login.

# 3. Start everything (creates, migrates and seeds the database on first boot)
docker compose up -d
```

The API listens on `http://localhost:3000` (`WEB_PORT` in `.env` changes it). This starts PostgreSQL, Redis, ClickHouse, the Rails API and the 5 Sidekiq worker processes. Uploaded assets are stored in the `storage` volume and served by the app; set `ACTIVE_STORAGE_SERVICE=amazon` and the `AWS_S3_*` variables to use S3 or MinIO instead.

Pin a release with `GROVS_IMAGE=ghcr.io/grovs-io/backend:1.4.0` in `.env` rather than tracking `latest`. To run from a source checkout instead, `docker build -t grovs-backend .` and set `GROVS_IMAGE=grovs-backend`.

For a real deployment set `SERVER_HOST`, `REACT_HOST`, `DOMAIN_LIVE`, `DOMAIN_TEST`, `S3_ASSET_PREFIX` and `PREVIEW_BASE_URL` to your own domain, and put a TLS-terminating reverse proxy in front of port 3000 that forwards the `api.`, `sdk.`, `go.`, `preview.` and link subdomains to it.

ClickHouse is the event store (`CLICKHOUSE_PRIMARY=true` in `.env.example`); `web` creates and migrates its database on boot.

### Local Development (without Docker)

**Prerequisites:** Ruby 3.4, PostgreSQL 16, Redis 6+, ClickHouse (optional — only needed if running analytics locally via `bin/dev`)

```bash
# Install dependencies and set up git hooks
bin/setup

# Generate encryption keys (first time)
bin/rails db:encryption:init
# Add the output to your .env

# Create and seed the database
bin/rails db:create db:migrate db:seed

# Start all services (Rails, Sidekiq, ClickHouse)
bin/dev
```

This uses [Foreman](https://github.com/ddollar/foreman) to start all processes defined in `Procfile.dev`. Logs from each service are color-coded and prefixed. Press `Ctrl+C` to stop everything.

To start a subset of services:

```bash
bin/dev -m web,sidekiq
```

## Configuration

Copy `.env.example` to `.env` and configure. Key groups:

| Group | Required | Variables |
|-------|----------|-----------|
| **Encryption** | Yes | `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `_DETERMINISTIC_KEY`, `_KEY_DERIVATION_SALT` |
| **Redis** | Yes | `REDIS_URL` (`rediss://` supported; `REDIS_SSL_CA_FILE` for a private CA) |
| **Server** | Yes | `SERVER_HOST_PROTOCOL`, `SERVER_HOST` (bare domain), `DOMAIN_LIVE`, `DOMAIN_TEST` |
| **Dashboard** | Yes | `REACT_HOST_PROTOCOL`, `REACT_HOST` |
| **Database** | Prod only | `DATABASE_URL` |
| **Object storage** | Prod only | `AWS_S3_KEY_ID`, `AWS_S3_ACCESS_KEY`, `AWS_S3_REGION`, `AWS_S3_BUCKET`, `S3_ASSET_PREFIX`; `S3_ENDPOINT` for MinIO/Ceph |
| **Email** | For emails | `SENDGRID_API_KEY`, or `MAILER_DELIVERY_METHOD=smtp` with `SMTP_*` and `MAILER_FROM` |
| **Stripe** | For billing | `STRIPE_API_KEY`, `STRIPE_STANDARD_PRICE_ID`, `STRIPE_WEBHOOK_SECRET` |
| **OAuth/SSO** | For social login | `GOOGLE_CLIENT_ID`/`SECRET`, `MICROSOFT_CLIENT_ID`/`SECRET` (each provider enabled only when both halves are set) |
| **GeoIP** | For geo features | `GEOIP_DB_PATH` pointing at a MaxMind GeoLite2 City `.mmdb` (not bundled) |
| **Client IP** | Behind a proxy | `CLIENT_IP_HEADER` (default `CF-Connecting-IP`; `X-Real-IP` behind nginx, `X-Forwarded-For` behind an AWS ALB) |
| **ClickHouse** | Optional | `CLICKHOUSE_URL`, `CLICKHOUSE_WRITE_ENABLED`, `CLICKHOUSE_READ_ENABLED`, read flags (see below) |
| **Feature flags** | Optional | `GROVS_EE`, `GROVS_SELF_HOSTED`, `CUSTOM_DOMAINS_ENABLED`, `MIGRATIONS_ENABLED` |
| **Bootstrap** | First deploy | `BOOTSTRAP_ADMIN_EMAIL`/`_PASSWORD`, `OAUTH_CLIENT_UID`/`_SECRET` |

See `.env.example` for full documentation of every variable.

## ClickHouse Analytics (optional)

Analytics run on PostgreSQL by default. ClickHouse can take over event storage and the analytics reads; every flag defaults to off, so an install without ClickHouse behaves exactly as before.

| Variable | Default | Effect |
|----------|---------|--------|
| `CLICKHOUSE_URL` | `http://localhost:8123` | HTTP endpoint; put credentials in the URL (`http://user:pass@host:8123`) |
| `CLICKHOUSE_DATABASE` | `grovs_<env>` | Database name |
| `CLICKHOUSE_WRITE_ENABLED` | `false` | Write events to ClickHouse alongside PostgreSQL |
| `CLICKHOUSE_READ_ENABLED` | `false` | Allow analytics reads from ClickHouse |
| `CLICKHOUSE_ANALYTICS_ROLLUPS_READ_ENABLED` | `false` | Dashboard counts come from ClickHouse rollups |
| `CLICKHOUSE_ATTRIBUTION_READ_ENABLED` | `false` | Per-visitor attribution comes from ClickHouse |
| `CLICKHOUSE_LINK_DIMENSIONS_READ_ENABLED` | `false` | Link list and link metrics come from ClickHouse |
| `CLICKHOUSE_PRIMARY` | `false` | Events are stored in ClickHouse only, with a PostgreSQL spill fallback. Requires write and read enabled |
| `CLICKHOUSE_ROLLUP_FAST_LANE` | `false` | Rebuild the current month's rollups every minute for fresher dashboards |
| `DASHBOARD_CACHE_TTL_SECONDS` | `300` | Dashboard cache lifetime |

```bash
# Create the database and run the ClickHouse migrations
bin/rails clickhouse:setup

# Apply pending ClickHouse migrations only
bin/rails clickhouse:migrate

# Rebuild rollups (after a backfill or when changing read flags)
bin/rails clickhouse:rebuild_rollups
```

Enable the flags in order: writes first, then reads, then the rollup and attribution read flags, and `CLICKHOUSE_PRIMARY` last. `bin/dev` starts a local ClickHouse via `run_clickhouse.sh`. ClickHouse 25.3 or newer is required.

## Enterprise Edition

Everything under `ee/` loads when `GROVS_EE=true`. Without it the core edition runs unchanged and the enterprise routes do not exist.

- **IAP revenue tracking** — Apple and Google webhooks, purchase validation, revenue attribution
- **Audit log** — Tamper-evident, hash-chained record of every administrative action. Instance admins issue read-only export tokens and a SIEM pulls `GET /api/v1/instances/:id/audit_events`. Verify a chain with `bin/rails audit:verify[<instance_id>]`
- **Enterprise SSO** — Per-instance OIDC connections with verified email domains, configured at `PUT /api/v1/instances/:id/sso_connection`
- **SCIM 2.0** — User provisioning and deactivation from the identity provider at `/scim/v2`, authenticated with a per-instance SCIM token

Production use of enterprise features requires a subscription. See [ee/LICENSE](ee/LICENSE).

## Self-hosting

Set `GROVS_SELF_HOSTED=true` for a single-tenant deployment. It serves uploaded assets through the app instead of signed S3 redirects, skips the SaaS-only seed data, grants custom-domain entitlement without billing, and turns the audit log on.

- **First admin** — Set `BOOTSTRAP_ADMIN_EMAIL` and `BOOTSTRAP_ADMIN_PASSWORD` before the first `db:seed`, or run `bin/rails grovs:ensure_bootstrap_admin` later. Set `OAUTH_CLIENT_UID` and `OAUTH_CLIENT_SECRET` so the dashboard's OAuth client has known credentials.
- **Email** — `MAILER_DELIVERY_METHOD=smtp` with `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_DOMAIN`, and `MAILER_FROM`.
- **Custom domains without Cloudflare** — `CUSTOM_DOMAINS_ENABLED=true` and `CUSTOM_DOMAINS_PROVIDER=manual`. Customers CNAME to `SELF_HOSTED_INGRESS_HOST` (defaults to `SERVER_HOST`); the domain activates through an HTTPS self-probe, the verify endpoint, or `bin/rails grovs:custom_domain:activate[<hostname>]`.
- **Competitor migration** — `MIGRATIONS_ENABLED=true`, then create a migration source per project with Branch or AppsFlyer credentials. Domains the provider owns (for example `xyz.app.link`) can be attached as provider-hosted sources for SDK-side resolution.
- **Logging** — `RAILS_LOG_LEVEL` (default `error`); logs go to stdout.
- **Health check** — `GET /up` needs no auth and no database round-trip.

## Background Workers

The app uses 5 Sidekiq processes with dedicated queues:

| Process | Config | Concurrency | Purpose |
|---------|--------|-------------|---------|
| worker | `sidekiq_worker.yml` | 40 (`SIDEKIQ_EVENTS_CONCURRENCY`) | SDK event ingestion |
| batch | `sidekiq_batch.yml` | 3 (`SIDEKIQ_BATCH_CONCURRENCY`) | Batch event processing |
| scheduler | `sidekiq_scheduler.yml` | 1 | Cron-based scheduled jobs |
| device_updates | `sidekiq_device_updates.yml` | 10 | Device metadata updates |
| maintenance | `sidekiq_maintenance.yml` | 5 | Backfills, rollup rebuilds and housekeeping |

All workers start automatically with `bin/dev`. To run workers individually:

```bash
bundle exec sidekiq -C config/sidekiq_worker.yml
```

## Testing

The project uses **Minitest** with fixtures. `.env.test` ships with deterministic dummy values so the suite runs out of the box.

```bash
# Core suite plus the Enterprise Edition suite (run this before pushing)
bin/rails test:full

# Core suite only (test/)
bin/rails test

# Enterprise Edition suite only (ee/test, sets GROVS_EE=true)
bin/rails test:ee

# Run a specific file or directory
bin/rails test test/models/device_test.rb
bin/rails test test/services/
```

ClickHouse-backed tests skip when no ClickHouse is reachable on `CLICKHOUSE_URL`. Set `CLICKHOUSE_REQUIRED=true` to make them fail instead, as CI should.

## Linting

Code style is enforced with [RuboCop](https://rubocop.org/). A pre-commit hook runs automatically if you ran `bin/setup`.

```bash
# Run RuboCop
bundle exec rubocop

# Auto-correct safe offenses
bundle exec rubocop -a
```

## Project Structure

```
app/
  controllers/
    api/v1/            # Dashboard API & SDK API endpoints
    public/            # Link redirect and display controllers
  models/              # ActiveRecord models
  services/            # Business logic (events, devices, attribution, ClickHouse reads)
  jobs/                # Sidekiq background jobs
  mailers/             # Transactional emails
ee/                    # Enterprise features (IAP/revenue, audit log, SSO/SCIM) — see license below
  app/                 # Controllers, models, services, jobs
  test/                # EE test suite
config/
  sidekiq_*.yml        # Sidekiq process configs
  routes.rb            # Subdomain-based routing
db/
  schema.rb            # Database schema (source of truth)
  migrate/             # PostgreSQL migrations
  clickhouse/migrate/  # ClickHouse migrations (forward-only, idempotent)
test/                  # Minitest test suite with fixtures
lib/
  clickhouse/          # ClickHouse migration framework
  tasks/               # Rake tasks (metrics, backfills, ClickHouse, debugging)
```

## Deployment

### Docker Compose (self-hosted)

`ghcr.io/grovs-io/backend` is the Community Edition image: built from `Dockerfile` with `GROVS_EE=false`, which deletes `ee/` at build time, so the Enterprise Edition (IAP revenue, audit log, OIDC/SCIM) is not present and cannot be switched on by environment. It runs as a non-root user with precompiled assets; `docker-compose.yml` runs every role from that one image. Upgrade with:

```bash
# bump GROVS_IMAGE in .env, then
docker compose pull && docker compose up -d   # web runs db:prepare, so pending migrations apply on boot
```

Releases are cut by hand from Actions -> Release (`.github/workflows/release.yml`). Every run executes the core and EE test suites, `bundler-audit`, Brakeman, a Trivy CVE scan of the built image, and a boot of this compose file against it with `GROVS_EE=true` to confirm the flag is inert. With "publish" on, it pushes the amd64 and arm64 image with SBOM and provenance, creates the `v*` tag, and attaches this compose file and `.env.example` to the GitHub Release.

### Kamal

Copy `config/deploy.yml.example` to `config/deploy.yml` and fill in your server IPs and registry credentials.

```bash
# First-time setup
bundle exec kamal setup

# Deploy
bundle exec kamal deploy
```

## SDKs

| Platform | Repository |
|----------|-----------|
| iOS | [grovs-io/grovs-ios](https://github.com/grovs-io/grovs-ios) |
| Android | [grovs-io/grovs-android](https://github.com/grovs-io/grovs-android) |
| React Native | [grovs-io/grovs-react-native](https://github.com/grovs-io/grovs-react-native) |
| Flutter | [grovs-io/grovs-flutter](https://github.com/grovs-io/grovs-flutter) |

## Contributing

We welcome contributions! Here's how:

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Ensure tests pass (`bin/rails test:full`) and RuboCop is clean (`bundle exec rubocop`)
5. Commit and push to your fork
6. Open a Pull Request

Please open an issue first for major changes to discuss the approach.

## License

Grovs uses a dual license model:

- **Core (MIT)** — Everything outside the `ee/` directory is licensed under the [MIT License](LICENSE). You can freely use, modify, and distribute it.
- **Enterprise** — The `ee/` directory contains enterprise features (IAP/revenue tracking, audit log, enterprise SSO and SCIM) under the [Grovs Enterprise License](ee/LICENSE). Production use of enterprise features requires a valid subscription.

See [LICENSE](LICENSE) and [ee/LICENSE](ee/LICENSE) for full terms.
