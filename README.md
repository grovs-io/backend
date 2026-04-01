<p align="center">
  <img src=".github/logo.svg" alt="Grovs" height="50">
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

- **Deep Linking** — Short links with deferred deep linking across iOS, Android, and web
- **Attribution** — Track installs, opens, reinstalls, and referrals back to their source
- **Revenue Tracking** — In-app purchase tracking with Apple/Google webhook integration and revenue attribution
- **Analytics** — Real-time dashboards with daily metrics, visitor stats, and campaign performance
- **Push Notifications** — Send targeted messages to your users via APNs and FCM
- **Multi-tenant** — One instance serves multiple apps across platforms

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Framework | Ruby on Rails 8.1 / Ruby 3.3.8 |
| Database | PostgreSQL 16 |
| Cache & Queues | Redis 6 |
| Background Jobs | Sidekiq with sidekiq-scheduler |
| Authentication | Devise + Doorkeeper (OAuth2) + OmniAuth (Google, Microsoft) |
| File Storage | AWS S3 via ActiveStorage |
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
```

The app is multi-tenant: **Instance** is the top-level tenant, each instance has a **test** and **production** Project. Users belong to instances via **InstanceRole**. Domains are attached to projects and resolve short links.

### API Routing (subdomain-based)

| Subdomain | Purpose | Auth |
|-----------|---------|------|
| `api.*` | Dashboard API (CRUD, analytics, config) | Doorkeeper OAuth2 |
| `sdk.*` | Mobile SDK (events, links, purchases) | Device fingerprint |
| `go.*` | Short link redirects | None |
| `preview.*` | Link previews | None |

## Quick Start

### Docker Compose (recommended)

```bash
# 1. Clone the repo
git clone https://github.com/grovs-io/backend.git
cd backend

# 2. Copy and configure environment variables
cp .env.example .env
# Edit .env — at minimum set the encryption keys (see below)

# 3. Generate ActiveRecord encryption keys
docker compose run --rm web bin/rails db:encryption:init
# Copy the 3 keys into your .env file

# 4. Start everything
docker compose up --build

# 5. Create the database (first time only)
docker compose exec web bundle exec rails db:create db:migrate db:seed
```

The app will be available at `http://localhost:8765`. This starts PostgreSQL, Redis, the Rails web server, and 5 Sidekiq worker processes.

### Local Development (without Docker)

**Prerequisites:** Ruby 3.3.8, PostgreSQL 16, Redis 6+, Node.js

```bash
# Install dependencies and set up git hooks
bin/setup

# Generate encryption keys (first time)
bin/rails db:encryption:init
# Add the output to your .env

# Create and seed the database
bin/rails db:create db:migrate db:seed

# Start the Rails server
bin/rails server

# Start all Sidekiq workers (separate terminal)
./run_sidekiq.sh
```

## Configuration

Copy `.env.example` to `.env` and configure. Key groups:

| Group | Required | Variables |
|-------|----------|-----------|
| **Encryption** | Yes | `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `_DETERMINISTIC_KEY`, `_KEY_DERIVATION_SALT` |
| **Redis** | Yes | `REDIS_URL` |
| **Server** | Yes | `SERVER_HOST_PROTOCOL`, `SERVER_HOST` |
| **Dashboard** | Yes | `REACT_HOST_PROTOCOL`, `REACT_HOST` |
| **Database** | Prod only | `DATABASE_URL` |
| **AWS S3** | For file uploads | `AWS_S3_KEY_ID`, `AWS_S3_ACCESS_KEY`, `AWS_S3_REGION`, `AWS_S3_BUCKET` |
| **Email** | For emails | `SENDGRID_API_KEY` |
| **Stripe** | For billing | `STRIPE_API_KEY`, `STRIPE_STANDARD_PRICE_ID`, `STRIPE_WEBHOOK_SECRET` |
| **OAuth/SSO** | For SSO login | `GOOGLE_CLIENT_ID`/`SECRET`, `MICROSOFT_CLIENT_ID`/`SECRET` |

See `.env.example` for full documentation of every variable.

## Background Workers

The app uses 5 Sidekiq processes with dedicated queues:

| Process | Config | Concurrency | Purpose |
|---------|--------|-------------|---------|
| worker | `sidekiq_worker.yml` | 20 | SDK event ingestion |
| batch | `sidekiq_batch.yml` | 3 | Batch event processing |
| scheduler | `sidekiq_scheduler.yml` | 1 | Cron-based scheduled jobs |
| device_updates | `sidekiq_device_updates.yml` | 3 | Device metadata updates |
| maintenance | `sidekiq_maintenance.yml` | 5 | Backfills and housekeeping |

Start all workers at once for development:

```bash
./run_sidekiq.sh
```

## Testing

The project uses **Minitest** with fixtures.

```bash
# Run the full test suite
bin/rails test

# Run a specific file
bin/rails test test/models/device_test.rb

# Run a specific directory
bin/rails test test/services/
```

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
  services/            # Business logic (events, devices, IAP, attribution)
  jobs/                # Sidekiq background jobs
  mailers/             # Transactional emails
ee/                    # Enterprise features (IAP/revenue) — see license below
config/
  sidekiq_*.yml        # Sidekiq process configs
  routes.rb            # Subdomain-based routing
db/
  schema.rb            # Database schema (source of truth)
  migrate/             # Migrations
test/                  # Minitest test suite with fixtures
lib/
  tasks/               # Rake tasks (metrics, backfills, debugging)
```

## Deployment

### Docker Compose (self-hosted)

```bash
docker compose up -d --build
```

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
4. Ensure tests pass (`bin/rails test`) and RuboCop is clean (`bundle exec rubocop`)
5. Commit and push to your fork
6. Open a Pull Request

Please open an issue first for major changes to discuss the approach.

## License

Grovs uses a dual license model:

- **Core (MIT)** — Everything outside the `ee/` directory is licensed under the [MIT License](LICENSE). You can freely use, modify, and distribute it.
- **Enterprise** — The `ee/` directory contains enterprise features (IAP/revenue tracking) under the [Grovs Enterprise License](ee/LICENSE). Production use of enterprise features requires a valid subscription.

See [LICENSE](LICENSE) and [ee/LICENSE](ee/LICENSE) for full terms.
