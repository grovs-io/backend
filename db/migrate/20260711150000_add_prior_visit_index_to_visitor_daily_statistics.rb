# frozen_string_literal: true

# Matches the equality+range predicate in DailyProjectMetricsGenerator#fetch_visitor_classification.
class AddPriorVisitIndexToVisitorDailyStatistics < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :visitor_daily_statistics,
              [:project_id, :platform, :visitor_id, :event_date],
              name: :idx_vds_prior_visit_lookup,
              algorithm: :concurrently,
              if_not_exists: true
  end
end
