module Grovs
  # True only when the flag is set AND the code shipped; the CE image deletes ee/ at build time.
  def self.ee?
    ENV.fetch("GROVS_EE", "false") == "true" && Rails.root.join("ee/app").directory?
  end

  def self.configured_link_asset_url(environment_key, filename)
    configured_url = ENV[environment_key].to_s.strip
    return configured_url if configured_url.present?

    protocol = ENV.fetch("SERVER_HOST_PROTOCOL", "https://").to_s.strip
    protocol = "https://" if protocol.blank?
    protocol = "#{protocol}://" unless protocol.end_with?("://")
    host = ENV.fetch("SERVER_HOST", "api.grovs.io").to_s.strip.sub(%r{/+\z}, "")

    "#{protocol}#{host}/assets/#{filename}"
  end

  module Roles
    ADMIN = "admin"
    MEMBER = "member"
    ALL = [ADMIN, MEMBER].freeze
  end

  module Platforms
    IOS = "ios"
    ANDROID = "android"
    DESKTOP = "desktop"
    TABLET = "tablet"
    PHONE = "phone"
    MAC = "mac"
    WINDOWS = "windows"
    WEB = "web"
    ALL = [IOS, ANDROID, DESKTOP, WINDOWS, MAC, WEB].freeze
    VARIATIONS = [TABLET, PHONE, MAC, WINDOWS, DESKTOP].freeze
  end

  module Events
    APP_OPEN = "app_open"
    VIEW = "view"
    OPEN = "open"
    INSTALL = "install"
    REINSTALL = "reinstall"
    TIME_SPENT = "time_spent"
    REACTIVATION = "reactivation"
    USER_REFERRED = "user_referred"
    SCREEN_VIEW = "screen_view"
    CUSTOM = "custom"
    ALL = [APP_OPEN, VIEW, OPEN, INSTALL, REINSTALL, TIME_SPENT, REACTIVATION, USER_REFERRED, SCREEN_VIEW, CUSTOM].freeze
    # Event names that clients must not use as custom event_name values.
    # screen_view is excluded because add_custom_event explicitly handles it.
    RESERVED_EVENT_NAMES = (ALL - [SCREEN_VIEW, CUSTOM]).to_set.freeze
    # Maps system event types to LinkDailyStatistic/VisitorDailyStatistic counter columns.
    # CUSTOM and SCREEN_VIEW are intentionally omitted — they flow to ClickHouse only
    # and do not increment PG dashboard stat counters.
    MAPPING = {
      VIEW => :views,
      OPEN => :opens,
      INSTALL => :installs,
      REINSTALL => :reinstalls,
      TIME_SPENT => :time_spent,
      REACTIVATION => :reactivations,
      APP_OPEN => :app_opens,
      USER_REFERRED => :user_referred
    }.freeze
  end

  module Subdomains
    PROXY = "proxy"
    SDK = "sdk"
    API = "api"
    GO = "go"
    PREVIEW = "preview"
    MCP = "mcp"
    FORBIDDEN = [SDK, API, GO, PROXY, PREVIEW, MCP].freeze
  end

  module Domains
    LIVE = ENV.fetch('DOMAIN_LIVE', 'sqd.link')
    TEST = ENV.fetch('DOMAIN_TEST', 'test-sqd.link')

    # One normal form for env-configured hosts: lowercase, scheme/path/port/root-dot stripped.
    def self.normalize_env_host(value)
      value.to_s.downcase.sub(%r{\Ahttps?://}, '').sub(%r{/.*}, '').sub(/:\d+\z/, '').chomp('.').presence
    end

    # lvh.me → 127.0.0.1 via public DNS with wildcard subdomains (dev convenience).
    MAIN = [normalize_env_host(LIVE), normalize_env_host(TEST),
            normalize_env_host(ENV['SERVER_HOST']),
            'localhost', 'lvh.me', 'trycloudflare.com'].compact.uniq.freeze

    # Routing tolerates a reserved-prefixed SERVER_HOST, but generated URLs do not
    # (api.api.<host>, SSO redirects, Pub/Sub endpoints) — so boot must be loud.
    def self.server_host_misconfiguration
      host = normalize_env_host(ENV['SERVER_HOST'])
      return nil unless host

      label, rest = host.split('.', 2)
      return nil unless rest && Subdomains::FORBIDDEN.include?(label)

      "SERVER_HOST=#{ENV['SERVER_HOST']} starts with the reserved subdomain '#{label}.'. " \
        "Set SERVER_HOST to the bare domain (#{rest}) — the #{Subdomains::FORBIDDEN.join('/')} " \
        'hosts are derived from it.'
    end

    # Longest-suffix host split — MAIN domains can be 3+ labels self-hosted, where
    # request.domain/subdomain's 2-label assumption misparses. nil when no MAIN
    # suffix matches; a reserved-prefixed MAIN entry splits against its own parent.
    def self.split(host)
      h = host.to_s.downcase.chomp('.')
      return nil if h.empty?

      main = MAIN.select { |d| h == d || h.end_with?(".#{d}") }.max_by(&:length)
      return nil unless main
      return [h.delete_suffix(".#{main}"), main] unless h == main

      # A MAIN entry that is itself <reserved>.<parent> (SERVER_HOST=api.acme.com,
      # DOMAIN_TEST=preview.x.y) is that reserved host, not an apex with a blank label.
      label, rest = main.split('.', 2)
      rest && Subdomains::FORBIDDEN.include?(label) ? [label, rest] : ["", main]
    end
  end

  module RedisKeys
    IMAGE_PREFIX = "REDIS_IMAGE_PREFIX"
    TITLE_PREFIX = "REDIS_TITLE_PREFIX"
    APPSTORE_PREFIX = "REDIS_APPSTORE_PREFIX"
  end

  module Assets
    # Public CDN defaults so self-hosted emails render branding without extra env.
    LOGO_LARGE = ENV.fetch("ASSET_LOGO_LARGE_URL", "https://appssemble-assets.s3.eu-north-1.amazonaws.com/linksquared/logo-large-black.png")
    LOGO_SQUARE = ENV.fetch("ASSET_LOGO_SQUARE_URL", "https://appssemble-assets.s3.eu-north-1.amazonaws.com/linksquared/logo-square-white.png")
    ATTENTION_ICON = ENV.fetch("ASSET_ATTENTION_ICON_URL", "https://appssemble-assets.s3.eu-north-1.amazonaws.com/linksquared/Attention+Square.png")
    DOWNLOAD_ICON = ENV.fetch("ASSET_DOWNLOAD_ICON_URL", "https://appssemble-assets.s3.eu-north-1.amazonaws.com/linksquared/download_icon.png")
    LINKEDIN_ICON = ENV.fetch("ASSET_LINKEDIN_ICON_URL", "https://designesy.s3.eu-north-1.amazonaws.com/semaphr/linkedin.png")
    GITHUB_ICON = ENV.fetch("ASSET_GITHUB_ICON_URL", "https://designesy.s3.eu-north-1.amazonaws.com/semaphr/github.png")
  end

  module Links
    VALIDITY_MINUTES = 5
    CLIPBOARD_VALIDITY = 48.hours
    LOGO = Grovs.configured_link_asset_url("DEFAULT_LOGO_URL", "logo-square-black.png")
    SOCIAL_PREVIEW = Grovs.configured_link_asset_url("DEFAULT_SOCIAL_PREVIEW_URL", "logo-large-black.png")
    DEFAULT_TITLE = ENV.fetch("DEFAULT_LINK_TITLE", "grovs")
    DEFAULT_SUBTITLE = ENV.fetch("DEFAULT_LINK_SUBTITLE", "Dynamic links, attributions, and referrals across mobile and web platforms.")
  end

  module Enrichment
    MAX_STRING_LENGTH = 255
    MAX_TAGS = 20
    MAX_PROPERTIES_BYTES = 8192
  end

  module Ads
    PLATFORMS = ["google", "meta", "tiktok", "linkedin", "quick-link"].freeze
  end

  module Webhooks
    APPLE = "apple"
    GOOGLE = "google"
    SOURCES = [APPLE, GOOGLE].freeze
  end

  module Apple
    # App Store Server Notification `data.environment` values.
    ENV_PRODUCTION = "Production"
    ENV_SANDBOX = "Sandbox"
    ENVIRONMENTS = [ENV_PRODUCTION, ENV_SANDBOX].freeze
  end

  module Purchases
    EVENT_BUY = "buy"
    EVENT_CANCEL = "cancel"
    EVENT_REFUND = "refund"
    EVENT_REFUND_REVERSED = "refund_reversed"
    ALL_EVENTS = [EVENT_BUY, EVENT_CANCEL, EVENT_REFUND, EVENT_REFUND_REVERSED].freeze
    TYPE_SUBSCRIPTION = "subscription"
    TYPE_ONE_TIME = "one_time"
    TYPE_RENTAL = "rental"
    TYPES = [TYPE_SUBSCRIPTION, TYPE_ONE_TIME, TYPE_RENTAL].freeze
  end

  module SSO
    MICROSOFT = "microsoft_graph"
    GOOGLE = "google_oauth2"
    OIDC = "oidc"
    ENV_CONNECTION = "grovs.sso_connection"
    ENV_SETUP_ERROR = "grovs.sso_setup_error"

    # Lives here, not in the service, so the omniauth initializer can call it
    # without autoloading app/ during boot.
    PROVIDER_ENV_KEYS = {
      GOOGLE => %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET],
      MICROSOFT => %w[MICROSOFT_CLIENT_ID MICROSOFT_CLIENT_SECRET]
    }.freeze

    def self.provider_configured?(provider)
      keys = PROVIDER_ENV_KEYS[provider]
      return false if keys.nil?

      keys.all? { |key| !ENV[key].to_s.strip.empty? }
    end

    def self.available_providers
      PROVIDER_ENV_KEYS.keys.select { |provider| provider_configured?(provider) }
    end

    def self.enabled?
      available_providers.any?
    end
  end

  module Migrations
    PROVIDER_BRANCH    = "branch"
    PROVIDER_APPSFLYER = "appsflyer"
    MVP_PROVIDERS = [PROVIDER_BRANCH, PROVIDER_APPSFLYER].freeze
    GENERATED_FROM_PLATFORM = "migration"
  end

  # Adding a purpose requires updates to: the custom_hostnames CHECK constraint, the
  # composite unique index on (project_id, purpose), this constant, the model validator,
  # and any controller param allowlist that accepts purpose.
  module Hostnames
    PURPOSE_PRIMARY = "primary"
    PURPOSE_MIGRATION = "migration"
    PURPOSES = [PURPOSE_PRIMARY, PURPOSE_MIGRATION].freeze
  end

  def self.free_mau_count
    ENV.fetch("FREE_MAU_COUNT", "10000").to_i
  end

  # Default false → every self-hosted branch is a no-op on SaaS/private deployments.
  def self.self_hosted?
    ENV["GROVS_SELF_HOSTED"] == "true"
  end

  # SMTP configured for outbound mail — self-hosted installs without it must not attempt delivery.
  def self.smtp_enabled?
    ENV["MAILER_DELIVERY_METHOD"] == "smtp"
  end

  # Only an explicitly falsey value goes cold — re-enabling never backfills the gap.
  def self.pg_shadow_writes?
    raw = ENV["PG_SHADOW_WRITES"]
    return true if raw.blank?

    ActiveModel::Type::Boolean.new.cast(raw) != false
  end

  # Reads ENV per call so tests can toggle.
  def self.cloudflare_custom_domains?
    ENV["CLOUDFLARE_API_TOKEN"].present? &&
      ENV["CLOUDFLARE_ZONE_ID"].present? &&
      ENV["CLOUDFLARE_SAAS_CNAME_TARGET"].present?
  end

  def self.custom_domains_provider
    ENV["CUSTOM_DOMAINS_PROVIDER"].presence || "cloudflare"
  end

  # Mode for NEW hostnames only; existing rows are read from CustomHostname#manual?.
  def self.manual_custom_domains?
    custom_domains_provider == "manual"
  end

  # SERVER_HOST already resolves to the load balancer, so it is a valid CNAME target by default.
  def self.ingress_host
    host = ENV["SELF_HOSTED_INGRESS_HOST"].presence || ENV["SERVER_HOST"].to_s
    host.strip.sub(%r{\Ahttps?://}, "").sub(/:\d+\z/, "").presence
  end

  def self.custom_domains_enabled?
    ENV["CUSTOM_DOMAINS_ENABLED"] == "true" && (manual_custom_domains? || cloudflare_custom_domains?)
  end

  def self.migrations_enabled?
    ENV["MIGRATIONS_ENABLED"] == "true" && custom_domains_enabled?
  end

  GOOGLE_PUBLISHER_SCOPE = 'https://www.googleapis.com/auth/androidpublisher'.freeze
end

# Otherwise the operator sees only a bare 404 and cannot tell "off" from "misconfigured".
if ENV["CUSTOM_DOMAINS_ENABLED"] == "true" && !Grovs.custom_domains_enabled?
  Rails.logger.warn(
    message: "custom_domains_disabled_despite_flag",
    hint: "Set CUSTOM_DOMAINS_PROVIDER=manual, or supply CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_ID " \
          "and CLOUDFLARE_SAAS_CNAME_TARGET."
  )
elsif ENV["CUSTOM_DOMAINS_ENABLED"] == "true" && Grovs.manual_custom_domains? && Grovs.ingress_host.blank?
  Rails.logger.warn(
    message: "custom_domains_manual_missing_ingress_host",
    hint: "Set SERVER_HOST or SELF_HOSTED_INGRESS_HOST so setup instructions have a CNAME target."
  )
end

# Fail fast in production: routing survives this misconfig but generated URLs don't.
# The console is exempt so an operator can still get a shell to diagnose the box.
if (server_host_message = Grovs::Domains.server_host_misconfiguration)
  raise server_host_message if Rails.env.production? && !defined?(Rails::Console)

  Rails.logger.warn(message: "server_host_reserved_prefix", hint: server_host_message)
end
