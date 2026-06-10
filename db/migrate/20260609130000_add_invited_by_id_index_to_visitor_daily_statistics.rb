class AddInvitedByIdIndexToVisitorDailyStatistics < ActiveRecord::Migration[8.1]
  disable_ddl_transaction! # CONCURRENTLY can't run inside a transaction

  # Partial index on invited_by_id for inviter point-lookups (VisitorReferralStatisticsQuery).
  # Already built in prod; if_not_exists makes this a no-op there, builds it elsewhere.
  def change
    add_index :visitor_daily_statistics, :invited_by_id,
              where: "invited_by_id IS NOT NULL",
              algorithm: :concurrently,
              name: "idx_vds_invited_by_id",
              if_not_exists: true
  end
end
