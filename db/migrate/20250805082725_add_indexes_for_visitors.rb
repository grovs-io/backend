class AddIndexesForVisitors < ActiveRecord::Migration[7.0]
   disable_ddl_transaction!

  def up
    # 1. Visitor statistics index (with INCLUDE) - for aggregation queries
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_visitor_stats_visitor_date
      ON visitor_daily_statistics (visitor_id, event_date)
      INCLUDE (views, opens, installs, reinstalls, time_spent, reactivations, app_opens, user_referred, revenue)
    SQL

    # 2. Devices index with INCLUDE (for later join pagination)
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_devices_id_with_platform
      ON devices (id)
      INCLUDE (platform)
    SQL

    # 3. Optional index for sorting by project and created_at (Rails-compatible)
    unless index_exists?(:visitors, [:project_id, :created_at], name: 'idx_visitors_project_created_desc')
      add_index :visitors,
                [:project_id, :created_at],
                order: { created_at: :desc },
                name: 'idx_visitors_project_created_desc',
                algorithm: :concurrently
    end
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_visitor_stats_visitor_date"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_devices_id_with_platform"
    remove_index :visitors, name: 'idx_visitors_project_created_desc' if index_exists?(:visitors, name: 'idx_visitors_project_created_desc')
  end
end
