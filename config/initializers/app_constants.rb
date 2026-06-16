module Grovs
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
    ALL = [APP_OPEN, VIEW, OPEN, INSTALL, REINSTALL, TIME_SPENT, REACTIVATION, USER_REFERRED].freeze
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

  module Domains
    LIVE = ENV.fetch('DOMAIN_LIVE', 'sqd.link')
    TEST = ENV.fetch('DOMAIN_TEST', 'test-sqd.link')
    # lvh.me resolves to 127.0.0.1 via public DNS — works locally with no /etc/hosts entries.
    MAIN = [LIVE, TEST, ENV['SERVER_HOST'], 'localhost', 'lvh.me', 'trycloudflare.com'].compact.freeze
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

  module RedisKeys
    IMAGE_PREFIX = "REDIS_IMAGE_PREFIX"
    TITLE_PREFIX = "REDIS_TITLE_PREFIX"
    APPSTORE_PREFIX = "REDIS_APPSTORE_PREFIX"
  end

  module Assets
    LOGO_LARGE = ENV.fetch("ASSET_LOGO_LARGE_URL", "")
    LOGO_SQUARE = ENV.fetch("ASSET_LOGO_SQUARE_URL", "")
    ATTENTION_ICON = ENV.fetch("ASSET_ATTENTION_ICON_URL", "")
    DOWNLOAD_ICON = ENV.fetch("ASSET_DOWNLOAD_ICON_URL", "")
    LINKEDIN_ICON = ENV.fetch("ASSET_LINKEDIN_ICON_URL", "")
    GITHUB_ICON = ENV.fetch("ASSET_GITHUB_ICON_URL", "")
  end

  module Links
    VALIDITY_MINUTES = 5
    LOGO = ENV.fetch("DEFAULT_LOGO_URL", "")
    SOCIAL_PREVIEW = ENV.fetch("DEFAULT_SOCIAL_PREVIEW_URL", "")
    DEFAULT_TITLE = ENV.fetch("DEFAULT_LINK_TITLE", "grovs")
    DEFAULT_SUBTITLE = ENV.fetch("DEFAULT_LINK_SUBTITLE", "Dynamic links, attributions, and referrals across mobile and web platforms.")
  end

  module Ads
    PLATFORMS = ["google", "meta", "tiktok", "linkedin", "quick-link"].freeze
  end

  module Webhooks
    APPLE = "apple"
    GOOGLE = "google"
    SOURCES = [APPLE, GOOGLE].freeze
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

  # Reads ENV per call so tests can toggle.
  def self.custom_domains_enabled?
    ENV["CUSTOM_DOMAINS_ENABLED"] == "true" &&
      ENV["CLOUDFLARE_API_TOKEN"].present? &&
      ENV["CLOUDFLARE_ZONE_ID"].present? &&
      ENV["CLOUDFLARE_SAAS_CNAME_TARGET"].present?
  end

  # Implicitly depends on custom_domains_enabled? because the customer's old host must be
  # attached as a CustomHostname for TLS + AASA.
  def self.migrations_enabled?
    ENV["MIGRATIONS_ENABLED"] == "true" && custom_domains_enabled?
  end

  GOOGLE_PUBLISHER_SCOPE = 'https://www.googleapis.com/auth/androidpublisher'.freeze
end
