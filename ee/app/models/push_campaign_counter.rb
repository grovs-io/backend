# A slice of a campaign's hot counters, bumped in the settle's transaction; readers sum them.
class PushCampaignCounter < ApplicationRecord
  self.primary_key = %i[push_campaign_id shard]
  SHARDS = 16
  COUNTERS = %i[queued delivered failed].freeze

  belongs_to :push_campaign

  # Made with the campaign: an inserting bump takes an FK lock on the row delivery holds FOR UPDATE.
  def self.create_shards!(campaign_id) = insert_all(Array.new(SHARDS) { |shard| { push_campaign_id: campaign_id, shard: shard } })

  # Fixed per thread, so a transaction bumping one campaign twice uses one shard.
  def self.shard = [Process.pid, Thread.current.object_id].hash % SHARDS

  UPSERT_SQL = <<~SQL.freeze
    INSERT INTO push_campaign_counters AS c (push_campaign_id, shard, queued, delivered, failed, error_counts)
    VALUES (:id, :shard, :queued, :delivered, :failed, CAST(:errors AS jsonb))
    ON CONFLICT (push_campaign_id, shard) DO UPDATE SET
      queued = c.queued + EXCLUDED.queued, delivered = c.delivered + EXCLUDED.delivered, failed = c.failed + EXCLUDED.failed,
      error_counts = c.error_counts || COALESCE((SELECT jsonb_object_agg(e.key, COALESCE((c.error_counts->>e.key)::bigint, 0) + e.value::bigint)
                                                 FROM jsonb_each_text(EXCLUDED.error_counts) e), '{}'::jsonb)
  SQL

  def self.bump!(campaign_id, errors: {}, **counters)
    values = COUNTERS.index_with { |col| Integer(counters.fetch(col, 0)) }
    sql = sanitize_sql_array([UPSERT_SQL, values.merge(id: Integer(campaign_id), shard: shard, errors: errors.transform_values { Integer(_1) }.to_json)])
    with_connection { |c| c.exec_update(sql) }
  end
end
