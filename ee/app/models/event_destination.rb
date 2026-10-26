class EventDestination < ApplicationRecord
  include Hashid::Rails

  KINDS = %w[webhook s3].freeze
  STATUSES = %w[enabled paused].freeze
  ALL_EVENT_TYPES = (Grovs::Events::ALL + ["purchase"]).freeze
  DEFAULT_EVENT_TYPES = (ALL_EVENT_TYPES - [Grovs::Events::TIME_SPENT, Grovs::Events::SCREEN_VIEW]).freeze
  MAX_BATCH_SIZE = 500
  MAX_CONCURRENCY = 16
  PAUSE_AFTER = 24.hours
  S3_FLUSH_INTERVAL = 300
  MAX_BACKOFF = 600
  CURSOR_COLUMNS = { events_at: :events_cursor_at, events_id: :events_cursor_id,
                     purchases_at: :purchases_cursor_at, purchases_id: :purchases_cursor_id }.freeze

  belongs_to :project
  belongs_to :created_by_user, class_name: "User", optional: true

  encrypts :signing_secret
  encrypts :credentials

  attribute :event_types, :string, array: true, default: -> { DEFAULT_EVENT_TYPES.dup }

  validates :name, presence: true, length: { maximum: 255 }
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :batch_size, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_BATCH_SIZE }
  validates :concurrency, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_CONCURRENCY }
  validate :event_types_known
  validate :settings_for_kind

  scope :enabled, -> { where(status: "enabled") }

  def webhook? = kind == "webhook"
  def s3? = kind == "s3"
  def enabled? = status == "enabled"
  def paused? = status == "paused"

  def url = settings["url"]

  def due?(now)
    return false unless enabled?
    return false if backoff_until && backoff_until > now
    return true unless s3?

    next_delivery_at.nil? || next_delivery_at <= now
  end

  def credentials_hash
    credentials.present? ? JSON.parse(credentials) : {}
  end

  def credentials_hash=(hash)
    self.credentials = hash.presence&.to_json
  end

  def generate_signing_secret
    self.signing_secret = "whsec_#{SecureRandom.hex(32)}"
  end

  def record_success!(cursor:, delivered:)
    record_partial!(cursor: cursor, delivered: delivered,
                    extra: { consecutive_failures: 0, failing_since: nil, backoff_until: nil, last_error: nil })
  end

  # Bookmark and counters only: a run that also failed must keep its failure clock running.
  def record_partial!(cursor:, delivered:, extra: {})
    attrs = { last_attempt_at: Time.current, delivered_count: delivered_count + delivered }
    attrs[:last_delivered_at] = Time.current if delivered.positive?
    update!(attrs.merge(extra).merge(cursor_attrs(cursor)))
  end

  def advance!(cursor)
    update!(cursor_attrs(cursor))
  end

  def record_idle!(cursor:)
    attrs = s3? ? { next_delivery_at: Time.current + S3_FLUSH_INTERVAL } : {}
    update!(cursor_attrs(cursor).merge(attrs))
  end

  def record_failure!(error)
    now = Time.current
    failures = consecutive_failures + 1
    since = failing_since || now
    message = error.to_s.truncate(1000)
    if since <= now - PAUSE_AFTER
      update!(status: "paused", paused_reason: "auto: failing since #{since.utc.iso8601}", last_error: message,
              consecutive_failures: failures, failing_since: since, last_attempt_at: now, backoff_until: nil)
      return :paused
    end
    update!(consecutive_failures: failures, failing_since: since, last_attempt_at: now, last_error: message,
            backoff_until: now + [10 * (2**[failures - 1, 6].min), MAX_BACKOFF].min)
    :backoff
  end

  def pause!(reason)
    update!(status: "paused", paused_reason: reason, backoff_until: nil)
  end

  def resume!
    update!(status: "enabled", paused_reason: nil, failing_since: nil, backoff_until: nil, consecutive_failures: 0, last_error: nil, next_delivery_at: nil)
  end

  def rewind!(to:)
    update!(events_cursor_at: to, events_cursor_id: "", purchases_cursor_at: to, purchases_cursor_id: "", next_delivery_at: nil)
  end

  private

  def cursor_attrs(cursor)
    cursor.slice(*CURSOR_COLUMNS.keys).transform_keys(CURSOR_COLUMNS)
  end

  def event_types_known
    unknown = Array(event_types) - ALL_EVENT_TYPES
    errors.add(:event_types, "unknown: #{unknown.join(', ')}") if unknown.any?
    errors.add(:event_types, "must not be empty") if Array(event_types).empty?
  end

  def check_public_url(value, field)
    uri = begin
      URI.parse(value.to_s)
    rescue URI::InvalidURIError
      nil
    end
    https = uri.is_a?(URI::HTTPS) || (uri.is_a?(URI::HTTP) && Rails.env.local?)
    if !https
      errors.add(:settings, "#{field} must be an https URL")
    elsif settings_changed? && EventStream::HostGuard.blocked?(uri.host)
      errors.add(:settings, "#{field} must not resolve to a private address")
    end
  end

  def check_custom_headers
    headers = credentials_hash["headers"]
    return if headers.nil? || (headers.is_a?(Hash) && headers.all? { |name, value| name.is_a?(String) && value.is_a?(String) })

    errors.add(:credentials, "headers must be a map of strings")
  end

  def check_s3_endpoint(value)
    uri = URI.parse(value.to_s)
    if !uri.is_a?(URI::HTTPS) || uri.host.blank?
      errors.add(:settings, "endpoint must be an https URL")
    elsif settings_changed? && EventStream::HostGuard.blocked?(uri.host)
      errors.add(:settings, "endpoint must not resolve to a private address")
    end
  rescue URI::InvalidURIError
    errors.add(:settings, "endpoint must be an https URL")
  end

  def settings_for_kind
    s = settings.is_a?(Hash) ? settings : {}
    case kind
    when "webhook"
      check_public_url(s["url"], "url")
      check_custom_headers
    when "s3"
      errors.add(:settings, "bucket is required") if s["bucket"].blank?
      errors.add(:settings, "region is required") if s["region"].blank?
      check_s3_endpoint(s["endpoint"]) if s["endpoint"].present? && !Grovs.self_hosted?
      creds = credentials_hash
      if !Grovs.self_hosted? && (creds["access_key_id"].blank? || creds["secret_access_key"].blank?)
        errors.add(:credentials, "access_key_id and secret_access_key are required")
      end
    end
  end
end
