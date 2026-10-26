class EventDestinationSerializer < BaseSerializer
  attributes :name, :kind, :status, :paused_reason, :event_types, :batch_size, :concurrency, :include_ip,
             :consecutive_failures, :last_error, :last_attempt_at, :last_delivered_at, :delivered_count,
             :backoff_until, :failing_since, :created_at, :updated_at

  def build(**)
    h = super()
    h["id"] = record.hashid
    h["settings"] = record.settings
    h["has_credentials"] = record.credentials.present?
    h["events_cursor_at"] = record.events_cursor_at&.utc&.iso8601(3)
    h["purchases_cursor_at"] = record.purchases_cursor_at&.utc&.iso8601(3)
    h["lag_seconds"] = record.events_cursor_at ? (Time.current - record.events_cursor_at).to_i : nil
    h
  end
end
