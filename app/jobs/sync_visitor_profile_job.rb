# frozen_string_literal: true

# An SDK identity change lands only in Postgres; without this the CH-served sort/search stays stale.
class SyncVisitorProfileJob < ApplicationJob
  queue_as :default

  WriteFailedError = Class.new(StandardError)

  def perform(visitor_id)
    return unless Clickhouse.enabled?

    visitor = Visitor.find_by(id: visitor_id)
    device = visitor&.device
    return if device.nil?

    # upsert_user_profile swallows CH errors and returns false; raise so Sidekiq retries.
    written = ClickhouseWriteService.upsert_user_profile(
      project_id: visitor.project_id,
      visitor_id: visitor.id,
      sdk_identifier: visitor.sdk_identifier.to_s,
      uuid: visitor.uuid.to_s,
      properties: ensure_hash(visitor.sdk_attributes),
      first_seen: visitor.created_at,
      last_seen: Time.current,
      country: GeoipService.lookup(device.remote_ip)[:country].to_s,
      platform: device.platform_for_metrics,
      inviter_id: visitor.inviter_id || 0
    )
    raise WriteFailedError, "user_profiles upsert failed for visitor #{visitor_id}" unless written
  end

  private

  def ensure_hash(raw)
    parsed = raw.is_a?(String) ? (JSON.parse(raw) rescue nil) : raw
    parsed.is_a?(Hash) ? parsed : {}
  end
end
