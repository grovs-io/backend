require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false

  # Disable serving static files from the `/public` folder by default since
  # Apache or NGINX already handles this.
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present?

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :amazon

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.assume_ssl = true
  # config.force_ssl = true

  # Preview: INFO level logging (more verbose than production)
  # JSON format for Signoz/OTEL log ingestion
  config.log_level = :info
  config.logger = ActiveSupport::Logger.new($stdout)
  config.logger.formatter = proc do |severity, datetime, _progname, msg|
    log_entry = {
      timestamp: datetime.iso8601(3),
      level: severity,
      message: msg,
      service: 'grovs-preview'
    }

    # Inject OpenTelemetry trace context if available
    begin
      if defined?(OpenTelemetry::Trace)
        span = OpenTelemetry::Trace.current_span
        ctx = span&.context
        if ctx && ctx.valid?
          log_entry[:trace_id] = ctx.hex_trace_id
          log_entry[:span_id] = ctx.hex_span_id
          log_entry[:trace_flags] = ctx.trace_flags.sampled? ? 1 : 0
        end
      end
    rescue StandardError
      # Silently ignore OTEL errors in logger
    end

    log_entry.to_json + "\n"
  end

  # Use Redis cache store
  config.cache_store = :redis_cache_store, {
    url: ENV.fetch("REDIS_URL") { "redis://localhost:6379/1" },
    namespace: 'grovs:cache:preview'
  }

  config.action_mailer.perform_caching = false

  # Enable locale fallbacks for I18n
  config.i18n.fallbacks = true

  # Send deprecation notices to registered listeners.
  config.active_support.deprecation = :notify

  # Log disallowed deprecations.
  config.active_support.disallowed_deprecation = :log

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Dynamic links - allow all hosts
  config.hosts = nil

  # Mailer config - same as production
  config.action_mailer.default_options = { from: 'Grovs <noreply@grovs.io>' }
  config.action_mailer.delivery_method = :sendgrid_actionmailer
  config.action_mailer.sendgrid_actionmailer_settings = {
    api_key: ENV['SENDGRID_API_KEY'],
    mail_settings: { sandbox_mode: { enable: false }}
  }
end
