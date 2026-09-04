class CreateAnalyticsConfigurations < ActiveRecord::Migration[8.0]
  def change
    create_table :analytics_configurations do |t|
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :stage_mappings, default: {}
      t.jsonb :flow_settings, default: {}
      t.timestamps
    end
  end
end
