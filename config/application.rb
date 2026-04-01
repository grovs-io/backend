require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "sprockets/railtie"
require "rails/test_unit/railtie"
require 'rack'
require 'rack/cors'
require_relative '../app/middleware/active_storage_error_handler'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Linksquared
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
    config.eager_load_paths += %W[#{config.root}/app/jobs]

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    config.active_job.queue_adapter = :sidekiq
    config.action_mailer.deliver_later_queue_name = :default

    # Add the lib files
    config.autoload_paths << Rails.root.join("lib").to_s
    config.autoload_paths << Rails.root.join("app/services").to_s

    # Enterprise Edition: conditionally load IAP/revenue features from ee/
    if ENV.fetch("GROVS_EE", "false") == "true"
      %w[controllers jobs services serializers].each do |subdir|
        path = Rails.root.join("ee", "app", subdir)
        if Dir.exist?(path)
          config.autoload_paths << path.to_s
          config.eager_load_paths << path.to_s
        end
      end
    end

    # Private extensions: load modules from an external directory.
    # Set GROVS_EXTENSIONS_PATH to the absolute path of the extensions dir.
    extensions_path = ENV["GROVS_EXTENSIONS_PATH"]
    if extensions_path.present?
      ext_root = Pathname.new(extensions_path)
      if ext_root.directory?
        lib_path = ext_root.join("lib")
        if lib_path.directory?
          config.autoload_paths << lib_path.to_s
          config.eager_load_paths << lib_path.to_s
        end
      end
    end

    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, key: '_linksquared'

    # Make sure CloudFlare IP addresses are
    # removed from the X-Forwarded-For header
    # before our app sees them
    config.middleware.insert_before(Rails::Rack::Logger,
      RemoteIpProxyScrubber.filter_middleware, 
      %w[
        173.245.48.0/20
        103.21.244.0/22
        103.22.200.0/22
        103.31.4.0/22
        141.101.64.0/18
        108.162.192.0/18
        190.93.240.0/20
        188.114.96.0/20
        197.234.240.0/22
        198.41.128.0/17
        162.158.0.0/15
        104.16.0.0/13
        104.24.0.0/14
        172.64.0.0/13
        131.0.72.0/22
    ])

    # Make sure the customer's real IP address (remote_ip)
    # is used in our Rails logs.
    config.middleware.insert_before(Rails::Rack::Logger, RemoteIpProxyScrubber.patched_logger)
    config.middleware.delete(Rails::Rack::Logger)


    config.active_record.encryption.primary_key = ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY']
    config.active_record.encryption.deterministic_key = ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY']
    config.active_record.encryption.key_derivation_salt = ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']

    config.active_record.encryption.support_unencrypted_data = true
    config.active_record.encryption.extend_queries = true


    # Delete this
    config.app_store_server = config_for :app_store_server

    config.middleware.use ActiveStorageErrorHandler

    # This is not necessarly good, but we want to have the source of the IP address for the user
    config.action_dispatch.trusted_proxies = [IPAddr.new("0.0.0.0/0")]


    config.lograge.enabled = true
    config.lograge.formatter = Lograge::Formatters::Json.new

    config.lograge.custom_options = lambda do |event|
      status = event.payload[:status] || 200

      severity =
        if status >= 500
          "ERROR"
        elsif status >= 400
          "WARN"
        else
          "INFO"
        end

      {
        environment: Rails.env,
        request_id: event.payload[:request_id],
        ip: event.payload[:remote_ip],
        user_agent: event.payload[:user_agent],
        severity: severity
      }
    end
  end
end
