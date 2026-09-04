# frozen_string_literal: true

# Durable device last-seen, stamped per batch; the SDK auth hot path reads this before any store.
class DeviceLastSeen < ApplicationRecord
  belongs_to :project
  belongs_to :device

  # stamps: { [project_id, device_id] => Time } — GREATEST-monotonic, rows sorted by conflict key.
  def self.stamp_batch!(stamps)
    return if stamps.empty?

    now = Time.current
    rows = stamps.sort_by { |pair, _| pair }.map do |(project_id, device_id), time|
      { project_id: project_id, device_id: device_id, last_seen_at: [time, now].min,
        created_at: now, updated_at: now }
    end
    upsert_all(
      rows,
      unique_by: %i[project_id device_id],
      returning: false,
      on_duplicate: Arel.sql(
        "last_seen_at = GREATEST(device_last_seens.last_seen_at, excluded.last_seen_at), " \
        "updated_at = excluded.updated_at"
      )
    )
  end
end
