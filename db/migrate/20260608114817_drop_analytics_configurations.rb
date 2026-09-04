class DropAnalyticsConfigurations < ActiveRecord::Migration[8.1]
  def up
    drop_table :analytics_configurations, if_exists: true
  end

  def down
    return if table_exists?(:analytics_configurations)

    create_table :analytics_configurations do |t|
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :stage_mappings, default: {}
      t.jsonb :flow_settings, default: {}
      t.timestamps
    end
  end
end
