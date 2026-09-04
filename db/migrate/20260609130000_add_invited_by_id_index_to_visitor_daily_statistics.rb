class AddInvitedByIdIndexToVisitorDailyStatistics < ActiveRecord::Migration[8.1]
  disable_ddl_transaction! # CONCURRENTLY can't run inside a transaction

  INDEX_NAME = "idx_vds_invited_by_id".freeze

  # Partial index on invited_by_id for inviter point-lookups (VisitorReferralStatisticsQuery).
  # Already built in prod; if_not_exists makes this a no-op there, builds it elsewhere.
  def up
    # A failed CREATE INDEX CONCURRENTLY leaves an INVALID index behind, which
    # if_not_exists would silently keep — drop it so this rerun rebuilds it.
    drop_index_if_invalid(INDEX_NAME, :visitor_daily_statistics)

    add_index :visitor_daily_statistics, :invited_by_id,
              where: "invited_by_id IS NOT NULL",
              algorithm: :concurrently,
              name: INDEX_NAME,
              if_not_exists: true
  end

  def down
    remove_index :visitor_daily_statistics, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  private

  def drop_index_if_invalid(name, table)
    invalid = select_value(<<~SQL)
      SELECT 1 FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = '#{name}' AND NOT i.indisvalid
    SQL
    remove_index table, name: name, algorithm: :concurrently, if_exists: true if invalid
  end
end
