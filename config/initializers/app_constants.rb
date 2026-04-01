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
    MAIN = [LIVE, TEST, ENV['SERVER_HOST'], 'localhost', 'trycloudflare.com'].freeze
  end

  module Subdomains
    PROXY = "proxy"
    SDK = "sdk"
    API = "api"
    GO = "go"
    PREVIEW = "preview"
    FORBIDDEN = [SDK, API, GO, PROXY, PREVIEW].freeze
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

  GOOGLE_PUBLISHER_SCOPE = 'https://www.googleapis.com/auth/androidpublisher'.freeze
end
